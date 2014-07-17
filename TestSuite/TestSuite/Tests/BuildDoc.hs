module TestSuite.Tests.BuildDoc (testGroupBuildDoc) where

import Data.Monoid
import Test.Tasty
import Test.HUnit
import qualified Data.Text as T

import IdeSession
import TestSuite.State
import TestSuite.Session
import TestSuite.Assertions

testGroupBuildDoc :: TestSuiteEnv -> TestTree
testGroupBuildDoc env = testGroup "Build haddocks" [
--    stdTest env "From some .lhs files" test_fromLhsFiles
--  , stdTest env "Fail"                 test_fail
  ]

{-
test_fromLhsFiles :: TestSuiteEnv -> Assertion
test_fromLhsFiles env = withAvailableSession env $ \session -> do
    status0 <- getBuildDocStatus session
    assertEqual "before module loading" Nothing status0
    withCurrentDirectory "test/compiler/utils" $ loadModulesFrom session "."
    assertNoErrors session
    let upd = buildDoc
    updateSessionD session upd 1
    status1 <- getBuildDocStatus session
    assertEqual "after doc build" (Just ExitSuccess) status1
    distDir <- getDistDir session
    indexExists <- doesFileExist $ distDir </> "doc/html/main/index.html"
    assertBool ".lhs haddock files" indexExists
    hoogleExists <- doesFileExist $ distDir </> "doc/html/main/main-1.0.txt"
    assertBool ".lhs hoogle files" hoogleExists

test_fail :: TestSuiteEnv -> Assertion
test_fail env = withAvailableSession env $ \session -> do
    withCurrentDirectory "test/ABerror" $ loadModulesFrom session "."
    assertOneError session
    let upd = buildDoc
    -- Note that the stderr log file here is empty, but exit code is 1:
    updateSessionD session upd 1
    status1 <- getBuildDocStatus session
    assertEqual "failure after doc build" (Just $ ExitFailure 1) status1
-}
