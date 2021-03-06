{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
-- |
-- Module      : Network.TLS.Core
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
module Network.TLS.Core
    (
    -- * Internal packet sending and receiving
      sendPacket
    , recvPacket

    -- * Initialisation and Termination of context
    , bye
    , handshake

    -- * Application Layer Protocol Negotiation
    , getNegotiatedProtocol

    -- * Server Name Indication
    , getClientSNI

    -- * High level API
    , sendData
    , recvData
    , recvData'
    , updateKey
    , KeyUpdateRequest(..)
    ) where

import Network.TLS.Cipher
import Network.TLS.Context
import Network.TLS.Crypto
import Network.TLS.Struct
import Network.TLS.Struct13
import Network.TLS.State (getSession)
import Network.TLS.Parameters
import Network.TLS.IO
import Network.TLS.Session
import Network.TLS.Handshake
import Network.TLS.Handshake.Common
import Network.TLS.Handshake.Common13
import Network.TLS.Handshake.State
import Network.TLS.Handshake.State13
import Network.TLS.KeySchedule
import Network.TLS.Util (catchException, mapChunks_)
import Network.TLS.Extension
import qualified Network.TLS.State as S
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Lazy as L
import qualified Control.Exception as E

import Control.Monad.State.Strict

-- | notify the context that this side wants to close connection.
-- this is important that it is called before closing the handle, otherwise
-- the session might not be resumable (for version < TLS1.2).
--
-- this doesn't actually close the handle
bye :: MonadIO m => Context -> m ()
bye ctx = do
  eof <- liftIO $ ctxEOF ctx
  tls13 <- tls13orLater ctx
  if tls13 then
      unless eof $ sendPacket13 ctx $ Alert13 [(AlertLevel_Warning, CloseNotify)]
    else
      unless eof $ sendPacket ctx $ Alert [(AlertLevel_Warning, CloseNotify)]

-- | If the ALPN extensions have been used, this will
-- return get the protocol agreed upon.
getNegotiatedProtocol :: MonadIO m => Context -> m (Maybe B.ByteString)
getNegotiatedProtocol ctx = liftIO $ usingState_ ctx S.getNegotiatedProtocol

type HostName = String

-- | If the Server Name Indication extension has been used, return the
-- hostname specified by the client.
getClientSNI :: MonadIO m => Context -> m (Maybe HostName)
getClientSNI ctx = liftIO $ usingState_ ctx S.getClientSNI

-- | sendData sends a bunch of data.
-- It will automatically chunk data to acceptable packet size
sendData :: MonadIO m => Context -> L.ByteString -> m ()
sendData ctx dataToSend = do
    tls13 <- tls13orLater ctx
    let sendP
          | tls13     = sendPacket13 ctx . AppData13
          | otherwise = sendPacket ctx . AppData
    liftIO (checkValid ctx)
    mapM_ (mapChunks_ 16384 sendP) (L.toChunks dataToSend)

-- | recvData get data out of Data packet, and automatically renegotiate if
-- a Handshake ClientHello is received
recvData :: MonadIO m => Context -> m B.ByteString
recvData ctx = do
    tls13 <- tls13orLater ctx
    if tls13 then recvData13 ctx else recvData1 ctx

recvData1 :: MonadIO m => Context -> m B.ByteString
recvData1 ctx = liftIO $ do
    checkValid ctx
    pkt <- withReadLock ctx $ recvPacket ctx
    either (onError terminate) process pkt
  where process (Handshake [ch@ClientHello{}]) =
            handshakeWith ctx ch >> recvData1 ctx
        process (Handshake [hr@HelloRequest]) =
            handshakeWith ctx hr >> recvData1 ctx

        process (Alert [(AlertLevel_Warning, CloseNotify)]) = tryBye ctx >> setEOF ctx >> return B.empty
        process (Alert [(AlertLevel_Fatal, desc)]) = do
            setEOF ctx
            E.throwIO (Terminated True ("received fatal error: " ++ show desc) (Error_Protocol ("remote side fatal error", True, desc)))

        -- when receiving empty appdata, we just retry to get some data.
        process (AppData "") = recvData1 ctx
        process (AppData x)  = return x
        process p            = let reason = "unexpected message " ++ show p in
                               terminate (Error_Misc reason) AlertLevel_Fatal UnexpectedMessage reason

        terminate = terminate' ctx (sendPacket ctx . Alert)

recvData13 :: MonadIO m => Context -> m B.ByteString
recvData13 ctx = liftIO $ do
    checkValid ctx
    pkt <- withReadLock ctx $ recvPacket13 ctx
    either (onError terminate) process pkt
  where process (Alert13 [(AlertLevel_Warning, CloseNotify)]) = tryBye ctx >> setEOF ctx >> return B.empty
        process (Alert13 [(AlertLevel_Fatal, desc)]) = do
            setEOF ctx
            E.throwIO (Terminated True ("received fatal error: " ++ show desc) (Error_Protocol ("remote side fatal error", True, desc)))
        process (Handshake13 hs) = do
            processHandshake13 hs
            recvData13 ctx
        -- when receiving empty appdata, we just retry to get some data.
        process (AppData13 "") = recvData13 ctx
        process (AppData13 x) = do
            let chunkLen = C8.length x
            established <- ctxEstablished ctx
            case established of
              EarlyDataAllowed maxSize
                | chunkLen <= maxSize -> do
                    setEstablished ctx $ EarlyDataAllowed (maxSize - chunkLen)
                    return x
                | otherwise ->
                    let reason = "early data overflow" in
                    terminate (Error_Misc reason) AlertLevel_Fatal UnexpectedMessage reason
              EarlyDataNotAllowed -> recvData13 ctx -- ignore "x"
              Established         -> return x
              NotEstablished      -> throwCore $ Error_Protocol ("data at not-established", True, UnexpectedMessage)
        process ChangeCipherSpec13 = recvData13 ctx
        process p             = let reason = "unexpected message " ++ show p in
                                terminate (Error_Misc reason) AlertLevel_Fatal UnexpectedMessage reason

        processHandshake13 [] = return ()
        processHandshake13 (ClientHello13{}:_) = do
            let reason = "Client hello is not allowed"
            terminate (Error_Misc reason) AlertLevel_Fatal UnexpectedMessage reason
        -- fixme: some implementations send multiple NST at the same time.
        -- Only the first one is used at this moment.
        processHandshake13 (NewSessionTicket13 life add nonce label exts:hs) = do
            ResuptionSecret resumptionMasterSecret <- usingHState ctx getTLS13Secret
            (usedHash, usedCipher, _) <- getTxState ctx
            let hashSize = hashDigestSize usedHash
                psk = hkdfExpandLabel usedHash resumptionMasterSecret "resumption" nonce hashSize
                maxSize = case extensionLookup extensionID_EarlyData exts >>= extensionDecode MsgTNewSessionTicket of
                  Just (EarlyDataIndication (Just ms)) -> fromIntegral $ safeNonNegative32 ms
                  _                                    -> 0
            tinfo <- createTLS13TicketInfo life (Right add) Nothing
            sdata <- getSessionData13 ctx usedCipher tinfo maxSize psk
            sessionEstablish (sharedSessionManager $ ctxShared ctx) label sdata
            -- putStrLn $ "NewSessionTicket received: lifetime = " ++ show life ++ " sec"
            processHandshake13 hs
        processHandshake13 (KeyUpdate13 UpdateNotRequested:hs) = do
            established <- ctxEstablished ctx
            -- Though RFC 8446 Sec 4.6.3 does not clearly says,
            -- unidirectional key update is legal.
            -- So, we don't have to check if this key update is corresponding
            -- to key update (update_requested) which we sent.
            if established == Established then do
                keyUpdate ctx getRxState setRxState
                processHandshake13 hs
              else do
                let reason = "received key update before established"
                terminate (Error_Misc reason) AlertLevel_Fatal UnexpectedMessage reason
        processHandshake13 (KeyUpdate13 UpdateRequested:hs) = do
            established <- ctxEstablished ctx
            if established == Established then do
                keyUpdate ctx getRxState setRxState
                sendPacket13 ctx $ Handshake13 [KeyUpdate13 UpdateNotRequested]
                keyUpdate ctx getTxState setTxState
                processHandshake13 hs
              else do
                let reason = "received key update before established"
                terminate (Error_Misc reason) AlertLevel_Fatal UnexpectedMessage reason
        processHandshake13 (h:hs) = do
            mPendingAction <- popPendingAction ctx
            case mPendingAction of
                Nothing -> let reason = "unexpected handshake message " ++ show h in
                           terminate (Error_Misc reason) AlertLevel_Fatal UnexpectedMessage reason
                Just pa -> withRWLock ctx (pa h) >> processHandshake13 hs

        terminate = terminate' ctx (sendPacket13 ctx . Alert13)

-- the other side could have close the connection already, so wrap
-- this in a try and ignore all exceptions
tryBye :: Context -> IO ()
tryBye ctx = catchException (bye ctx) (\_ -> return ())

onError :: Monad m => (TLSError -> AlertLevel -> AlertDescription -> String -> m B.ByteString)
                   -> TLSError -> m B.ByteString
onError _ Error_EOF = -- Not really an error.
            return B.empty
onError terminate err@(Error_Protocol (reason,fatal,desc)) =
    terminate err (if fatal then AlertLevel_Fatal else AlertLevel_Warning) desc reason
onError terminate err =
    terminate err AlertLevel_Fatal InternalError (show err)

terminate' :: Context -> ([(AlertLevel, AlertDescription)] -> IO ())
           -> TLSError -> AlertLevel -> AlertDescription -> String -> IO a
terminate' ctx send err level desc reason = do
    session <- usingState_ ctx getSession
    case session of
        Session Nothing    -> return ()
        Session (Just sid) -> sessionInvalidate (sharedSessionManager $ ctxShared ctx) sid
    catchException (send [(level, desc)]) (\_ -> return ())
    setEOF ctx
    E.throwIO (Terminated False reason err)


{-# DEPRECATED recvData' "use recvData that returns strict bytestring" #-}
-- | same as recvData but returns a lazy bytestring.
recvData' :: MonadIO m => Context -> m L.ByteString
recvData' ctx = L.fromChunks . (:[]) <$> recvData ctx

keyUpdate :: Context
          -> (Context -> IO (Hash,Cipher,C8.ByteString))
          -> (Context -> Hash -> Cipher -> C8.ByteString -> IO ())
          -> IO ()
keyUpdate ctx getState setState = do
    (usedHash, usedCipher, applicationTrafficSecretN) <- getState ctx
    let applicationTrafficSecretN1 = hkdfExpandLabel usedHash applicationTrafficSecretN "traffic upd" "" $ hashDigestSize usedHash
    setState ctx usedHash usedCipher applicationTrafficSecretN1

-- | How to update keys in TLS 1.3
data KeyUpdateRequest = OneWay -- ^ Unidirectional key update
                      | TwoWay -- ^ Bidirectional key update (normal case)
                      deriving (Eq, Show)

-- | Updating appication traffic secrets for TLS 1.3.
--   If this API is called for TLS 1.3, 'True' is returned.
--   Otherwise, 'False' is returned.
updateKey :: Context -> KeyUpdateRequest -> IO Bool
updateKey ctx way = do
    tls13 <- tls13orLater ctx
    when tls13 $ do
        let req = case way of
                OneWay -> UpdateNotRequested
                TwoWay -> UpdateRequested
        sendPacket13 ctx $ Handshake13 [KeyUpdate13 req]
        keyUpdate ctx getTxState setTxState
    return tls13
