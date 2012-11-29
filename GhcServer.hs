{-# LANGUAGE ScopedTypeVariables, TemplateHaskell #-}
-- | Implementation of the server that controls the long-running GHC instance.
-- This is the place where the GHC-specific part joins the part
-- implementing the general RPC infrastructure.
--
-- The modules importing any GHC internals, as well as the modules
-- implementing the  RPC infrastructure, should be accessible to the rest
-- of the program only indirectly, through the @GhcServer@ module.
module GhcServer
  ( -- * Types involved in the communication
    PCounter, GhcRequest(..), GhcResponse(..)
    -- * A handle to the server
  , GhcServer
    -- * Server-side operations
  , ghcServer
    -- * Client-side operations
  , forkGhcServer
  , rpcGhcServer
  , shutdownGhcServer
  ) where

-- getExecutablePath is in base only for >= 4.6
import qualified Control.Exception as Ex
import System.Environment.Executable (getExecutablePath)
import System.FilePath ((</>), takeExtension)
import System.Directory
import Data.Aeson.TH (deriveJSON)
import Control.Monad (void)
import Control.Concurrent
  ( forkIO
  , myThreadId
  )
import Control.Concurrent.MVar
  ( newMVar
  , putMVar
  , modifyMVar
  , takeMVar
  , isEmptyMVar
  )

import RpcServer
import Common
import GhcRun
import Progress

type PCounter = Int
data GhcRequest  =
  ReqCompute (Maybe [String]) FilePath Bool (Maybe (String, String))
  deriving Show
data GhcResponse = RespWorking PCounter | RespDone RunOutcome
  deriving Show

$(deriveJSON id ''GhcRequest)
$(deriveJSON id ''GhcResponse)

-- Keeps the dynamic portion of the options specified at server startup
-- (they are among the options listed in SessionConfig).
-- They are only fed to GHC if no options are set via a session update command.
newtype GhcInitData = GhcInitData { dOpts :: DynamicOpts }

type GhcServer = RpcServer GhcRequest GhcResponse

-- * Server-side operations

ghcServer :: [String] -> IO ()
ghcServer fdsAndOpts = do
  let (opts, markerAndFds) = span (/= "--ghc-opts-end") fdsAndOpts
  rpcServer (tail markerAndFds) (ghcServerEngine opts)

-- TODO: this function is getting too complex: boolean, Maybe, complex
-- results, etc.; perhaps change GhcRequest and GhcResponse to reflect
-- the options in a better way and split the code paths?
-- TODO: Do we want to return partial error information while it's
-- generated by runGHC, e.g., warnings? We could either try to run checkModule
-- file by file (do depanalSource and then DFS over the resulting graph,
-- doing \ m -> load (LoadUpTo m)) or rewrite collectSrcError to place
-- warnings in an mvar instead of IORef and read from it into Progress,
-- as soon as they appear.
ghcServerEngine :: [String]
                -> RpcServerActions GhcRequest GhcResponse GhcResponse
                -> IO ()
ghcServerEngine opts rpcActions@RpcServerActions{..} = do

  dOpts <- submitStaticOpts opts

  -- should do other init and runGhc here so dispatcher runs in Ghc monad
  dispatcher GhcInitData{..}

  where
    dispatcher ghcInitData = do
      req <- getRequest
      resp <- ghcServerHandler ghcInitData putProgress req
      putResponse resp
      dispatcher ghcInitData


--TODO: this should be in the Ghc monad:
ghcServerHandler :: GhcInitData -> (GhcResponse -> IO ()) -> GhcRequest
                 -> IO GhcResponse
ghcServerHandler GhcInitData{dOpts}
                 reportProgress (ReqCompute ideNewOpts configSourcesDir
                                            ideGenerateCode funToRun) = do

    mvCounter <- newMVar 0  -- Report progress step [0/n], too.

    cnts <- getDirectoryContents configSourcesDir
    let files = map (configSourcesDir </>)
                $ filter ((`elem` hsExtentions) . takeExtension) cnts

        dynOpts = maybe dOpts optsToDynFlags ideNewOpts
        -- Let GHC API print "compiling M ... done." for each module.
        verbosity = 1
        -- TODO: verify that _ is the "compiling M" message
        handlerOutput _ = do
          oldCounter <- modifyMVar mvCounter (\c -> return (c+1, c))
          reportProgress (RespWorking oldCounter)
        handlerRemaining _ = return ()  -- TODO: put into logs somewhere?

    runOutcome <- checkModule files dynOpts ideGenerateCode funToRun verbosity
                              handlerOutput handlerRemaining

    return (RespDone runOutcome)

-- * Client-side operations

forkGhcServer :: [String] -> IO GhcServer
forkGhcServer opts = do
  prog <- getExecutablePath
  forkRpcServer prog $ ["--server"] ++ opts ++ ["--ghc-opts-end"]

rpcGhcServer :: GhcServer -> (Maybe [String]) -> FilePath
             -> Bool -> Maybe (String, String)
             -> (Progress GhcResponse GhcResponse -> IO a) -> IO a
rpcGhcServer gs ideNewOpts configSourcesDir ideGenerateCode funToRun handler =
  rpcWithProgress gs (ReqCompute ideNewOpts configSourcesDir
                                 ideGenerateCode funToRun)
                     handler

shutdownGhcServer :: GhcServer -> IO ()
shutdownGhcServer gs = shutdown gs
