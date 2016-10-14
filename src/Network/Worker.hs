{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
module Network.Worker
  ( AMQP.fromURI
  , publish
  , publishToExchange
  , connect
  , disconnect
  , exchange
  , directQueue
  , topicQueue
  , initQueue
  , withChannel
  , consume
  , consumeNext
  , worker
  , RoutingKey(..)
  , BindingKey(..)
  , BindingName(..)
  , Exchange(..)
  , Queue(..)
  , Direct, Topic
  , WorkerException(..)
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException(..))
import Control.Monad.Catch (throwM, MonadThrow, Exception(..), catch, MonadCatch)
import Control.Monad (forever)
import Data.Aeson (ToJSON, FromJSON)
import qualified Data.Aeson as Aeson
import Data.ByteString.Lazy (ByteString)
import Data.String (IsString(..))
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Typeable (Typeable)
import Data.Pool (Pool)
import qualified Data.Pool as Pool
import qualified Data.List as List
import qualified Data.List.Split as List
-- import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Network.AMQP as AMQP
import Network.AMQP (Channel, newMsg, DeliveryMode(..), ExchangeOpts(..), QueueOpts(..), Ack(..))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Base (liftBase)


-- TODO when an exception happens handle it somehow?
-- TODO exception: make sure the connection still works
-- TODO worker in a loop.


-- TODO open a channel every time you want to use one: withChannel

-- TODO handle channel exception errors with addChannelExceptionHandler

-- TODO exchange and connection can be bundled together?
-- connection
-- exchange

class QueueKey key where
  showKey :: key -> Text

newtype RoutingKey = RoutingKey Text
  deriving (Show, Eq)

instance IsString RoutingKey where
  fromString = RoutingKey . Text.pack

instance QueueKey RoutingKey where
  showKey (RoutingKey t) = t


newtype BindingKey = BindingKey [BindingName]
  deriving (Eq)

instance QueueKey BindingKey where
  showKey (BindingKey ns) =
    Text.intercalate "." . List.map bindingNameText $ ns

instance IsString BindingKey where
  fromString s =
    let segments = List.splitOn "." s
        names = List.map fromString segments
    in BindingKey names


data BindingName
  = Name Text
  | Star
  | Hash
  deriving (Eq)

instance IsString BindingName where
  fromString "*" = Star
  fromString "#" = Hash
  fromString n = Name (Text.pack n)

bindingNameText :: BindingName -> Text
bindingNameText (Name t) = t
bindingNameText Star = "*"
bindingNameText Hash = "#"

type ExchangeName = Text


exchange :: Text -> Exchange
exchange nm =
  Exchange $ AMQP.newExchange { exchangeName = nm, exchangeType = "topic" }


topicQueue :: Exchange -> BindingKey -> Queue Topic msg
topicQueue exg key =
  Queue exg key $ AMQP.newQueue { queueName = showKey key }


directQueue :: Exchange -> RoutingKey -> Queue Direct msg
directQueue exg (RoutingKey key) =
  Queue exg (RoutingKey key) $ AMQP.newQueue { queueName = key }


newtype Exchange =
  Exchange AMQP.ExchangeOpts
  deriving (Show, Eq)

data Queue queueType msg =
  Queue Exchange queueType AMQP.QueueOpts
  deriving (Show, Eq)

type Direct = RoutingKey
type Topic = BindingKey



-- publish -----------------------------------------------

jsonMessage :: ToJSON a => a -> AMQP.Message
jsonMessage a = newMsg
  { AMQP.msgBody = Aeson.encode a
  , AMQP.msgContentType = Just "application/json"
  , AMQP.msgContentEncoding = Just "UTF-8"
  , AMQP.msgDeliveryMode = Just Persistent
  }


-- but the exchange is tied to the connnection for sure?
publishToExchange :: (ToJSON a, MonadBaseControl IO m) => Connection -> ExchangeName -> RoutingKey -> a -> m ()
publishToExchange conn exg (RoutingKey rk) msg =
  withChannel conn $ \chan -> do
    _ <- liftBase $ AMQP.publishMsg chan exg rk (jsonMessage msg)
    return ()


-- you can only publish to a direct queue
publish :: (ToJSON msg, MonadBaseControl IO m) => Connection -> Queue Direct msg -> msg -> m ()
publish conn (Queue (Exchange exg) key _) msg =
  publishToExchange conn (AMQP.exchangeName exg) key msg


-- I only care about the body and the stuff...
-- why do I have to care about the stupid body?
-- I don't! If I produce the real message you can serialize it
newtype Message a =
  Message (Either ParseError a)

-- I wish it could just be Message a!
-- basically I'm forcing anyone who uses this to handle invalid input. Is that what I want to do?

data ParseError =
  ParseError String ByteString
  deriving (Show, Eq)


-- has a body
-- either an error or a message

-- TODO I need to surface parse errors, rather than acknowledging them and swallowing.
-- don't throw an error. Much easier to know what's going on.
consume :: (FromJSON msg, MonadBaseControl IO m) => Connection -> Queue key msg -> m (Maybe (Message msg))
consume conn (Queue exg _ options) = do
  mme <- withChannel conn $ \chan ->
    liftBase $ AMQP.getMsg chan Ack (queueName options)

  case mme of
    Nothing ->
      return Nothing

    Just (msg, env) -> do
      liftBase $ AMQP.ackEnv env
      let body = AMQP.msgBody msg
      case Aeson.eitherDecode body of
        Left err ->
          return $ Just $ Message (Left $ ParseError err body)

        Right m ->
          return $ Just $ Message (Right m)



consumeNext :: (FromJSON msg, MonadBaseControl IO m) => Connection -> Queue key msg -> m (Message msg)
consumeNext conn queue = do
    poll pollDelay $ consume conn queue

  where
    pollDelay = 1 * 1000



worker :: (FromJSON a, ToJSON a, MonadBaseControl IO m, MonadCatch m) => Connection -> Queue key a -> (ByteString -> WorkerException SomeException -> m ()) -> (a -> m ()) -> m ()
worker conn queue onError action =
  forever $ do
    Message msg <- consumeNext conn queue
    case msg of
      Left (ParseError reason body) ->
        onError body (MessageParseError reason)

      Right m ->
        catch
          (action m)
          (onError (Aeson.encode m) . OtherException)

data WorkerException e
  = MessageParseError String
  | OtherException e
  deriving (Show, Eq)

instance (Exception e) => Exception (WorkerException e)





-- helpers ---------------------------------------------------

poll :: (MonadBaseControl IO m) => Int -> m (Maybe a) -> m a
poll us action = do
    ma <- action
    case ma of
      Just a -> return a
      Nothing -> do
        liftBase $ threadDelay us
        poll us action




-- connections ----------------------------------------------

data ConnResource = ConnResource AMQP.Connection Channel

type Connection = Pool ConnResource

-- data.pool, if it throws an exception of any kind, the resource is destroyed and not returned to the pool
-- required: don't use the same channel for two concurrent requests
-- TODO how to use a single connection, and only re-open it when necessary? (exceptions can close the connection)
connect :: AMQP.ConnectionOpts -> IO Connection
connect opts =
    Pool.createPool create destroy numStripes openTime numResources
  where
    numStripes = 1
    openTime = 10
    numResources = 4

    create = do
      conn <- AMQP.openConnection'' opts
      chan <- AMQP.openChannel conn
      return $ ConnResource conn chan

    destroy (ConnResource conn _) =
      AMQP.closeConnection conn

disconnect :: Connection -> IO ()
disconnect conn =
    Pool.destroyAllResources conn



withChannel :: MonadBaseControl IO m => Connection -> (Channel -> m b) -> m b
withChannel conn action =
    Pool.withResource conn chanAction
  where
    chanAction (ConnResource _ chan) =
      action chan


initQueue :: (QueueKey key) => Connection -> Queue key msg -> IO ()
initQueue conn (Queue (Exchange exg) key options) =
  withChannel conn $ \chan -> do
    _ <- AMQP.declareExchange chan exg
    _ <- AMQP.declareQueue chan options
    _ <- AMQP.bindQueue chan (AMQP.queueName options) (AMQP.exchangeName exg) (showKey key)
    return ()