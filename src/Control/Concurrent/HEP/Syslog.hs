{-#LANGUAGE DeriveDataTypeable#-}
{-#LANGUAGE BangPatterns#-}

module Control.Concurrent.HEP.Syslog 
    ( startSyslog
    , startSyslogSupervisor
    , syslogError
    , syslogInfo
    , stopSyslog
    , Control.Concurrent.HEP.Syslog.withSyslog
    )
    where

import Control.Concurrent.HEP as H
import Control.Concurrent
import Data.Typeable
import Control.Monad.Trans
import Control.Monad
import System.Posix.Syslog as S

data LoggerMessage = LogError String
                   | LogInfo String
                   | LogStop
                   | LogPing (MBox LogAnswer)
    deriving (Typeable)

data LogAnswer = LogAnswerOK

instance Message LoggerMessage

data LoggerState = LoggerState
    { loggerDone:: Bool
    }
    deriving Typeable
instance HEPLocalState LoggerState

pid = "HEPSysLogger"

{-
 - API function
 -}
startSyslogSupervisor:: String-> HEPProc-> HEP Pid
startSyslogSupervisor ident sv = do
    !pid <- spawn $! procWithSupervisor (proc sv) $! 
        procWithBracket loggerInit loggerShutdown $! procRegister pid $!
        proc $! loggerWorker ident
    inbox <- liftIO newMBox
    send pid $! LogPing inbox
    ret <- liftIO $! receiveMBoxAfter 1000 inbox
    case ret of 
        Just _ -> return pid
        _ -> do
            liftIO $! ioError $! userError $! "unable to spawn syslog client"
            return pid

startSyslog:: String-> HEP Pid
startSyslog ident = do
    spawn $! procWithBracket loggerInit loggerShutdown $! 
        procRegister pid $! proc $! loggerWorker ident

syslogInfo s = do
    send ( toPid pid) $! LogInfo s
    
syslogError s = send (toPid pid)  $! LogError s

stopSyslog = send (toPid pid) LogStop

loggerInit = do
    register "syslogClient"
    p <- self
    send p $! LogInfo "syslog client started"
    setLocalState $! Just $! LoggerState
        { loggerDone = False
        }
    procRunning

loggerShutdown = do
    procRunning

loggerWorker:: String-> HEP HEPProcState
loggerWorker ident = do
    mmsg <- receiveAfter 2000
    case mmsg of
        Nothing -> do
            Just ls <- localState
            case loggerDone ls of
                False-> procRunning
                _ -> do
                    spawn $! procForker forkOS $! proc $! 
                        _intSyslogInfo ident Info "syslog client stopped"
                    procFinished
        Just msg -> 
            case fromMessage msg of
                Nothing-> procRunning
                Just (LogPing outbox) -> do
                    liftIO $! sendMBox outbox LogAnswerOK
                    procRunning
                Just LogStop -> do
                    Just ls <- localState
                    setLocalState $! Just $! ls
                        { loggerDone = True
                        }
                    procRunning
                Just (LogError string) -> do
                    spawn $! procForker forkOS $! proc $!
                        _intSyslogError ident Error string
                    procRunning
                Just (LogInfo string) -> do
                    spawn $! procForker forkOS $! 
                        proc $!  _intSyslogInfo ident Info string
                    procRunning
        
_intSyslogError:: String-> Priority-> String-> HEP HEPProcState
_intSyslogError ident prio s = do
    liftIO $! S.withSyslog ident [PID, PERROR] USER $! syslog prio s
    procFinished
    
_intSyslogInfo:: String-> Priority-> String-> HEP HEPProcState
_intSyslogInfo ident prio s = do
    liftIO $! S.withSyslog ident [PID] USER $! syslog prio s
    procFinished

withSyslog:: String-> HEPProcOptions -> HEPProcOptions
withSyslog ident child = do
    let childInit = heppInit child
        childShutdown = heppShutdown child
    child
        { heppInit = (startSyslog ident >> childInit)
        , heppShutdown = (childShutdown >>= \x-> (stopSyslog >> return x))
        }
