{-#LANGUAGE DeriveDataTypeable#-}
{-#LANGUAGE BangPatterns#-}

module Control.Concurrent.HEP.Syslog 
    ( startSyslog
    , startSyslogSupervisor
    , syslogError
    , syslogInfo
    , stopSyslog
    )
    where

import Control.Concurrent.HEP
import Control.Concurrent
import Data.Typeable
import Control.Monad.Trans
import Control.Monad
import System.Posix.Syslog

data LoggerMessage = LogError String
                   | LogInfo String
                   | LogStop
                   | LogPing (MBox LogAnswer)
    deriving (Typeable)

data LogAnswer = LogAnswerOK

instance Message LoggerMessage

pid = "HEPSysLogger"

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
    p <- self
    send p $! LogInfo "syslog client started"
    procRunning

loggerShutdown = do
    procRunning

loggerWorker:: String-> HEP HEPProcState
loggerWorker ident = do
    msg <- receive
    case fromMessage msg of
        Nothing-> procRunning
        Just (LogPing outbox) -> do
            liftIO $! sendMBox outbox LogAnswerOK
            procRunning
        Just LogStop -> do
            spawn $! procForker forkOS $! proc $! 
                _intSyslogInfo ident Info "syslog client stopped"
            procFinished
        
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
    liftIO $! withSyslog ident [PID, PERROR] USER $! syslog prio s
    procFinished
    
_intSyslogInfo:: String-> Priority-> String-> HEP HEPProcState
_intSyslogInfo ident prio s = do
    liftIO $! withSyslog ident [PID] USER $! syslog prio s
    procFinished
