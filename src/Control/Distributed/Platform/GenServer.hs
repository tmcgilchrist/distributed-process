{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}

module Control.Distributed.Platform.GenServer (
    Name,
    Timeout(..),
    InitResult(..),
    CallResult(..),
    CastResult(..),
    Info(..),
    InfoResult(..),
    TerminateReason(..),
    serverStart,
    serverNCall,
    serverCall,
    serverReply,
    Server(..),
    defaultServer
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Monad                            (forever)
import           Prelude                                  hiding (catch, init)

--------------------------------------------------------------------------------
-- Data Types                                                                 --
--------------------------------------------------------------------------------
data InitResult
  = InitOk Timeout
  | InitStop String
  | InitIgnore

data CallResult r
  = CallOk r
  | CallStop String
  | CallDeferred

data CastResult
  = CastOk
  | CastStop String

data Info
  = InfoTimeout Timeout
  | Info String

data InfoResult
  = InfoNoReply Timeout
  | InfoStop String

data TerminateReason
  = TerminateNormal
  | TerminateShutdown
  | TerminateReason

-- | Server record of callbacks
data Server rq rs = Server {
    serverPorts     :: Process (SendPort rq, ReceivePort rq),
    handleInit      :: Process InitResult,                 -- ^ initialization callback
    handleCall      :: rq -> Process (CallResult rs),      -- ^ call callback
    handleCast      :: rq -> Process CastResult,                   -- ^ cast callback
    handleInfo      :: Info -> Process InfoResult,         -- ^ info callback
    handleTerminate :: TerminateReason -> Process ()  -- ^ termination callback
  }

defaultServer :: Server rq rs
defaultServer = Server {
  serverPorts = undefined,
  handleInit = return $ InitOk NoTimeout,
  handleCall = undefined,
  handleCast = \_ -> return $ CastOk,
  handleInfo = \_ -> return $ InfoNoReply NoTimeout,
  handleTerminate = \_ -> return ()
}

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Process name
type Name = String

-- | Process name
data Timeout = Timeout Int
             | NoTimeout

-- | Start server
--
serverStart :: (Serializable rq, Serializable rs)
      => Name
      -> Process (Server rq rs)
      -> Process (SendPort rq)
serverStart name createServer = do
    say $ "Starting server " ++ name
    server <- createServer

    sreq <- spawnChannelLocal $ \rreq -> do
      -- server process
      say $ "Initializing " ++ name
      -- init
      initResult <- handleInit server
      case initResult of
        InitIgnore -> do
          return () -- ???
        InitStop reason -> do
          say $ "Initialization stopped: " ++ reason
          return ()
        InitOk timeout -> do
          -- loop
          forever $ do
            case timeout of
              Timeout value -> do
                say $ "Waiting for call to " ++ name ++ " with timeout " ++ show value
                maybeMsg <- expectTimeout value
                case maybeMsg of
                  Just msg -> handle server msg
                  Nothing -> return ()
              NoTimeout       -> do
                say $ "Waiting for call to " ++ name
                msg <- receiveChan rreq -- :: Process (ProcessId, rq)
                handle server msg
                return ()
          -- terminate
          handleTerminate server TerminateNormal
    --say $ "Waiting for " ++ name ++ " to start"
    --sreq <- expect
    say $ "Process " ++ name ++ " initialized"
    register name $ sendPortProcessId . sendPortId $ sreq
    return sreq
  where
    handle :: (Serializable rs) => Server rq rs -> (ProcessId, rq) -> Process ()
    handle server (them, rq) = do
      say $ "Handling call for " ++ name
      callResult <- handleCall server rq
      case callResult of
        CallOk reply -> do
          say $ "Sending reply from " ++ name
          send them reply
        CallDeferred ->
          say $ "Not sending reply from " ++ name
        CallStop reason ->
          say $ "Not implemented!"

-- | Call a process using it's name
-- nsend doesnt seem to support timeouts?
serverNCall :: (Serializable a, Serializable b) => Name -> a -> Process b
serverNCall name rq = do
  (sport, rport) <- newChan
  nsend name (sport, rq)
  receiveChan rport
  --us <- getSelfPid
  --nsend name (us, rq)
  --expect

-- | call a process using it's process id
serverCall :: (Serializable a, Serializable b) => ProcessId -> a -> Timeout -> Process b
serverCall pid rq timeout = do
  (sport, rport) <- newChan
  send pid (sport, rq)
  case timeout of
    Timeout value -> do
      receiveChan rport
      maybeMsg <- error "not implemented" -- expectTimeout value
      case maybeMsg of
        Just msg -> return msg
        Nothing -> error "timeout!"
    NoTimeout -> receiveChan rport

-- | out of band reply to a client
serverReply :: (Serializable a) => SendPort a -> a -> Process ()
serverReply sport reply = do
  sendChan sport reply
