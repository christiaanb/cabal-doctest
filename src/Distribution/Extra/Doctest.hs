{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The provided 'generateBuildModule' generates 'Build_doctests' module.
-- That module exports enough configuration, so your doctests could be simply
--
-- @
-- module Main where
-- 
-- import Build_doctests (flags, pkgs, module_sources)
-- import Data.Foldable (traverse_)
-- import Test.Doctest (doctest)
-- 
-- main :: IO ()
-- main = do
--     traverse_ putStrLn args -- optionally print arguments
--     doctest args
--   where
--     args = flags ++ pkgs ++ module_sources
-- @
--
-- To use this library in the @Setup.hs@, you should specify a @custom-setup@ 
-- section in the cabal file, for example:
--
-- @
-- custom-setup
--  setup-depends:
--    base >= 4 && <5,
--    cabal-doctest >= 1 && <1.1
-- @
--
-- /Note:/ you don't need to depend on @Cabal@  if you use only
-- 'defaultMainWithDoctests' in the @Setup.hs@.
--
module Distribution.Extra.Doctest (
    defaultMainWithDoctests,
    doctestsUserHooks,
    generateBuildModule,
    ) where

-- Hacky way to suppress few deprecation warnings.
#if MIN_VERSION_Cabal(1,24,0)
#define InstalledPackageId UnitId
#endif

import Control.Monad
       (when)
import Data.List
       (nub)
import Data.String
       (fromString)
import Distribution.Package
       (InstalledPackageId)
import Distribution.Package
       (Package (..), PackageId, packageVersion)
import Distribution.PackageDescription
       (BuildInfo (..), Library (..), PackageDescription (), TestSuite (..))
import Distribution.Simple
       (UserHooks (..), defaultMainWithHooks, simpleUserHooks)
import Distribution.Simple.BuildPaths
       (autogenModulesDir)
import Distribution.Simple.Compiler
       (PackageDB (..), showCompilerId)
import Distribution.Simple.LocalBuildInfo
       (ComponentLocalBuildInfo (componentPackageDeps), LocalBuildInfo (),
       compiler, withLibLBI, withPackageDB, withTestLBI)
import Distribution.Simple.Setup
       (BuildFlags (buildDistPref, buildVerbosity), fromFlag)
import Distribution.Simple.Utils
       (createDirectoryIfMissingVerbose, rewriteFile)
import Distribution.Text
       (display, simpleParse)
import System.FilePath
       ((</>))

#if MIN_VERSION_Cabal(1,25,0)
import Distribution.Simple.BuildPaths
       (autogenComponentModulesDir)
#endif
#if MIN_VERSION_Cabal(2,0,0)
import Distribution.Types.MungedPackageId
#endif

#if MIN_VERSION_directory(1,2,2)
import System.Directory
       (makeAbsolute)
#else
import System.Directory
       (getCurrentDirectory)
import System.FilePath
       (isAbsolute)

makeAbsolute :: FilePath -> IO FilePath
makeAbsolute p | isAbsolute p = return p
               | otherwise    = do
    cwd <- getCurrentDirectory
    return $ cwd </> p
#endif

-- | A default main with doctests:
--
-- @
-- import Distribution.Extra.Doctest
--        (defaultMainWithDoctests)
--
-- main :: IO ()
-- main = defaultMainWithDoctests "doctests"
-- @
defaultMainWithDoctests
    :: String  -- ^ doctests test-suite name
    -> IO ()
defaultMainWithDoctests = defaultMainWithHooks . doctestsUserHooks

-- | 'simpleUserHooks' with 'generateBuildModule' prepended to the 'buildHook'.
doctestsUserHooks
    :: String  -- ^ doctests test-suite name
    -> UserHooks
doctestsUserHooks testsuiteName = simpleUserHooks
    { buildHook = \pkg lbi hooks flags -> do
       generateBuildModule testsuiteName flags pkg lbi
       buildHook simpleUserHooks pkg lbi hooks flags
    }

-- | Generate a build module for the test suite.
--
-- @
-- import Distribution.Simple
--        (defaultMainWithHooks, UserHooks(..), simpleUserHooks)
-- import Distribution.Extra.Doctest
--        (generateBuildModule)
--
-- main :: IO ()
-- main = defaultMainWithHooks simpleUserHooks
--     { buildHook = \pkg lbi hooks flags -> do
--         generateBuildModule "doctests" flags pkg lbi
--         buildHook simpleUserHooks pkg lbi hooks flags
--     }
-- @
generateBuildModule
    :: String -- ^ doctests test-suite name
    -> BuildFlags -> PackageDescription -> LocalBuildInfo -> IO ()
generateBuildModule testSuiteName flags pkg lbi = do
  let verbosity = fromFlag (buildVerbosity flags)
  let distPref = fromFlag (buildDistPref flags)

  -- Package DBs
  let dbStack = withPackageDB lbi ++ [ SpecificPackageDB $ distPref </> "package.conf.inplace" ]
  let dbFlags = "-hide-all-packages" : packageDbArgs dbStack

  withLibLBI pkg lbi $ \lib libcfg -> do
    let libBI = libBuildInfo lib

    -- modules
    let modules = exposedModules lib ++ otherModules libBI
    -- it seems that doctest is happy to take in module names, not actual files!
    let module_sources = modules

    -- We need the directory with library's cabal_macros.h!
#if MIN_VERSION_Cabal(1,25,0)
    let libAutogenDir = autogenComponentModulesDir lbi libcfg
#else
    let libAutogenDir = autogenModulesDir lbi
#endif

    -- Lib sources and includes
    iArgs <- mapM (fmap ("-i"++) . makeAbsolute) $ libAutogenDir : hsSourceDirs libBI
    includeArgs <- mapM (fmap ("-I"++) . makeAbsolute) $ includeDirs libBI

    -- default-extensions
    let extensionArgs = map (("-X"++) . display) $ defaultExtensions libBI

    -- CPP includes, i.e. include cabal_macros.h
    let cppFlags = map ("-optP"++) $
            [ "-include", libAutogenDir ++ "/cabal_macros.h" ]
            ++ cppOptions libBI

    withTestLBI pkg lbi $ \suite suitecfg -> when (testName suite == fromString testSuiteName) $ do

      -- get and create autogen dir
#if MIN_VERSION_Cabal(1,25,0)
      let testAutogenDir = autogenComponentModulesDir lbi suitecfg
#else
      let testAutogenDir = autogenModulesDir lbi
#endif
      createDirectoryIfMissingVerbose verbosity True testAutogenDir

      -- write autogen'd file
      rewriteFile (testAutogenDir </> "Build_doctests.hs") $ unlines
        [ "module Build_doctests where"
        , ""
        -- -package-id etc. flags
        , "pkgs :: [String]"
        , "pkgs = " ++ (show $ formatDeps $ testDeps libcfg suitecfg)
        , ""
        , "flags :: [String]"
        , "flags = " ++ show (iArgs ++ includeArgs ++ dbFlags ++ cppFlags ++ extensionArgs)
        , ""
        , "module_sources :: [String]"
        , "module_sources = " ++ show (map display module_sources)
        ]
  where
    -- we do this check in Setup, as then doctests don't need to depend on Cabal
    isOldCompiler = maybe False id $ do
      a <- simpleParse $ showCompilerId $ compiler lbi
      b <- simpleParse "7.5"
      return $ packageVersion (a :: PackageId) < b

    formatDeps = map formatOne
    formatOne (installedPkgId, pkgId)
      -- The problem is how different cabal executables handle package databases
      -- when doctests depend on the library
#if MIN_VERSION_Cabal(2,0,0)
      | computeCompatPackageId (packageId pkg) Nothing == pkgId
      = "-package=" ++ display pkgId
#else
      | packageId pkg == pkgId = "-package=" ++ display pkgId
#endif
      | otherwise              = "-package-id=" ++ display installedPkgId

    -- From Distribution.Simple.Program.GHC
    packageDbArgs :: [PackageDB] -> [String]
    packageDbArgs | isOldCompiler = packageDbArgsConf
                  | otherwise     = packageDbArgsDb

    -- GHC <7.6 uses '-package-conf' instead of '-package-db'.
    packageDbArgsConf :: [PackageDB] -> [String]
    packageDbArgsConf dbstack = case dbstack of
      (GlobalPackageDB:UserPackageDB:dbs) -> concatMap specific dbs
      (GlobalPackageDB:dbs)               -> ("-no-user-package-conf")
                                           : concatMap specific dbs
      _ -> ierror
      where
        specific (SpecificPackageDB db) = [ "-package-conf=" ++ db ]
        specific _                      = ierror
        ierror = error $ "internal error: unexpected package db stack: "
                      ++ show dbstack

    -- GHC >= 7.6 uses the '-package-db' flag. See
    -- https://ghc.haskell.org/trac/ghc/ticket/5977.
    packageDbArgsDb :: [PackageDB] -> [String]
    -- special cases to make arguments prettier in common scenarios
    packageDbArgsDb dbstack = case dbstack of
      (GlobalPackageDB:UserPackageDB:dbs)
        | all isSpecific dbs              -> concatMap single dbs
      (GlobalPackageDB:dbs)
        | all isSpecific dbs              -> "-no-user-package-db"
                                           : concatMap single dbs
      dbs                                 -> "-clear-package-db"
                                           : concatMap single dbs
     where
       single (SpecificPackageDB db) = [ "-package-db=" ++ db ]
       single GlobalPackageDB        = [ "-global-package-db" ]
       single UserPackageDB          = [ "-user-package-db" ]
       isSpecific (SpecificPackageDB _) = True
       isSpecific _                     = False

#if MIN_VERSION_Cabal(2,0,0)
testDeps :: ComponentLocalBuildInfo -> ComponentLocalBuildInfo -> [(InstalledPackageId, MungedPackageId)]
#else
testDeps :: ComponentLocalBuildInfo -> ComponentLocalBuildInfo -> [(InstalledPackageId, PackageId)]
#endif
testDeps xs ys = nub $ componentPackageDeps xs ++ componentPackageDeps ys
