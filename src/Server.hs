{- | Server is an internal implementation module of "HWebUI". "HWebUI" is providing FRP-based GUI functionality for Haskell by utilizing the Web-Browser. See module "HWebUI" for main documentation. 
-}

{-# OPTIONS_HADDOCK hide #-}

module Server (
  
  Webgui (..),
  Widget,
  
  -- ** The background server process (built on top of Yesod)
  -- $backgroundserver
  
  runHWebUIServer,
  waitForHWebUIServer
  
  ) where

import Yesod
import Network.Wai.Handler.Warp (runSettings, Settings(..), defaultSettings)
import qualified Network.WebSockets             as WS
import qualified Network.Wai.Handler.WebSockets as WS
import qualified Data.Aeson                     as J
import System.IO (hFlush, stdout)
import Control.Monad
import Control.Concurrent
import Control.Exception (mask, try)
import System.IO.Unsafe
import Control.Wire
import Prelude hiding ((.), id)
import Data.Map

import Messaging

-- this module implements the background server for the HWebUI GUI. The background server is based on Yesod und features:
-- - delivery of Javascript towards Browser
-- - delivery of basic webpage, which build the GUI
-- - handling of websocket interaction between Browser/JavaScript based GUI elements and Haskell FRP GUI elements


--------------------------------------------------------
-- the basic Yesod webserver, which handles static and dynamic content
--------------------------------------------------------


-- | the base data type included in the Yesod server for convenience
data Webgui = Webgui {
  guiLayout :: WidgetT Webgui IO () } -- ^ the layout of the page

mkYesod "Webgui" [parseRoutes|
/webgui   GuioneR GET
|]

instance Yesod Webgui 

-- we need a separate base layout, to include class="claro" in the body element

claroLayout :: Yesod site => WidgetT site IO () -> HandlerT site IO Html
claroLayout w = do
        p <- widgetToPageContent w
        mmsg <- getMessage
        giveUrlRenderer [hamlet|
            $newline never
            $doctype 5
            <html>
                <head>
                    <title>#{pageTitle p}
                    ^{pageHead p}
                <body class="claro">
                    $maybe msg <- mmsg
                        <p .message>#{msg}
                    ^{pageBody p}
            |]

-- Warning: Defined but not used: `jsUtils'
-- but it seems to have some use.
jsUtils :: JavascriptUrl url
jsUtils = [julius|
             function evtJson(evt, f) {
               var str;
               if(evt.data instanceof Blob) {
                 var reader = new FileReader();
                 reader.onload = function() {
                   f($.parseJSON(reader.result));
                 }
                 reader.readAsText(evt.data);
               } else {
                 f($.parseJSON(evt.data));
               }
             };
          |]

-- the one page which is delivered by the yesod web server
getGuioneR :: Handler Html
getGuioneR = do
  Webgui lt <- getYesod
  claroLayout lt


--------------------------------------------------------
-- utilities to send and receive JSON data over the websocket interface
--------------------------------------------------------


receiveJson :: J.FromJSON a => WS.WebSockets WS.Hybi10 a
receiveJson = do
  bs <- WS.receiveData
--  liftIO $ print ("to browser: " ++ (show bs))
--  liftIO $ hFlush stdout
  case J.decode' bs of
    Nothing -> sendJson (jsonError "invalid message") >> receiveJson
    Just a  -> return a

sendJson :: J.ToJSON a => a -> WS.WebSockets WS.Hybi10 ()
sendJson j = WS.sendBinaryData (J.encode j)

sendSinkJson :: J.ToJSON a => WS.Sink WS.Hybi10 -> a -> IO ()
sendSinkJson sink j = WS.sendSink sink $ WS.textData (J.encode j)

jsonError :: String -> Value
jsonError msg = J.object [ "error" .= msg ]


--------------------------------------------------------
-- code which handles the websocket interaction
--------------------------------------------------------

-- function, which accepts a new connection to the websocket and starts the socket handling upon that
socketAcceptFunction :: Map String GSChannel -> WS.Request -> WS.WebSockets WS.Hybi10 ()
socketAcceptFunction y req
  | WS.requestPath req == "/guisocket" = accept socketHandlingFunction
  | otherwise                      = WS.rejectRequest req "Not found"
  where
    accept a = WS.acceptRequest req >> a y


-- loop which regularly reads the messages from the websocket and distribute to the channels
readSocketLoop :: Map String GSChannel -> WS.WebSockets WS.Hybi10 ()
readSocketLoop gsmap = do
    item <- receiveJson
    case item of
         Just (GUIMessage gmId gmSignal gmValue gmType) -> do
                
--                liftIO $ print ("from browser: " ++ (show item))
--                liftIO $ hFlush stdout
                    
                liftIO $ receiveGMWriteChannel (gsmap ! gmId) (GUIMessage gmId gmSignal gmValue gmType)
                return ()
         _ -> return ()
           
    liftIO $ threadDelay 1000
    readSocketLoop gsmap
    return ()
  
-- function which spans a loop for writing to the websocket and runs later the loop to read websockets
socketHandlingFunction :: Map String GSChannel -> WS.WebSockets WS.Hybi10 ()
socketHandlingFunction gsmap = do
--  liftIO $ print "message Socket created"
--  liftIO $ hFlush stdout
  sink <- WS.getSink
  
  -- spawn a new process, which runs a loop forever to
  -- check incoming messages from the MVar lists and forwards them over the websockets interface
  -- (this is the write socket loop)
  
  let gsList = toList gsmap
  _ <- liftIO . forkIO . forever $ do
                   sequence_ $ fmap (\(k, v) -> do
                        gmsMB <- liftIO $ sendGMReadChannel v
                        case gmsMB of
                          Just guimsg -> do
                            liftIO $ sendSinkJson sink guimsg
                            return ()
                          Nothing -> 
                            return ()) gsList
                   liftIO $ threadDelay 1000
                   return ()
                          
  -- start readsocket in a loop
  -- (this is the readsocket loop)
  readSocketLoop gsmap
  return ()
  
-- | function which runs the Yesod webserver, together with the websocket, needed by GUI element communication
runWebserver :: Int -> Map String GSChannel -> WidgetT Webgui IO () -> IO ()
runWebserver port gsmap guiLayout = do
    let master = Webgui guiLayout
        s      = defaultSettings
                  { settingsPort = port
                  , settingsIntercept = WS.intercept $ socketAcceptFunction gsmap
                  }
    runSettings s =<< toWaiApp master


--------------------------------------------------------------
-- code which handles spawning a child process and wait for it
--------------------------------------------------------------



children :: MVar [MVar ()]
children = unsafePerformIO (newMVar [])
    
-- | wait for child process terminate
waitForChildren :: IO ()
waitForChildren = do
      cs <- takeMVar children
      case cs of
        []   -> return ()
        m:ms -> do
           putMVar children ms
           takeMVar m
           waitForChildren

-- | fork a child process
forkChild :: IO () -> IO ThreadId
forkChild io = do
        mvar <- newEmptyMVar
        childs <- takeMVar children
        putMVar children (mvar:childs)
        Server.forkFinally io (\_ -> putMVar mvar ())

-- | helper routine to fork a child
forkFinally :: IO a -> (Either SomeException a -> IO ()) -> IO ThreadId
forkFinally action and_then =
  mask $ \restore ->
    forkIO $ try (restore action) >>= and_then
    
-- | run the HWebUIServer in the background
runHWebUIServer :: Int -> Map String GSChannel -> WidgetT Webgui IO () -> IO ThreadId
runHWebUIServer port gsmap guiLayout = forkChild $ runWebserver port gsmap guiLayout

-- | wait for HWebUIServer to terminate
waitForHWebUIServer :: IO ()
waitForHWebUIServer = waitForChildren


{- $backgroundserver

To run a web based GUI, we need a background Webserver. In the case of HWebUI this purpose is achieved by leveraging the Yesod webserver. In addition to serving the HTML pages, which build the static framework for the GUI, the Yesod server also provides the mechanism to implement a websockets based communication between the Browser and the Haskell process running the FRP based GUI. All this functionality is implemented in a pilot implementation mode in the "Server" module. According to this explanation functionality in the "Server" module is grouped into two parts, one is about providing the HTML/Javascript based landing page for the GUI and one is to accept a connection for a websocket communication and handle this specific communication channel.

The function which runs the background server is called 'runWebserver' and it includes both parts, it defines a Yesod settings data structure, which includes the websocket interception option. It also creates the base type of the Yesod server which includes the layout of the landing page. This is needed, since we want flexible layouts for the landing page, not linked to the function running the server. Then it starts the the Yesod server.

The functions which implement the websocket communication are the 'socketAcceptFunction', 'readSocketLoop' and the 'socketHandlingFunction', which spawns the write loop for writing towards the socket and then calls the 'readSocketLoop' function. The 'socketAcceptFunction' is called given as the anchor function in the websocket configuration inside the 'runWebserver' function.

The basic Yesod webserver is implemented the usual way, two annotation may be made: there is a specific base layout defined to include the Dojokit "claro" style in the body element of the HTML page. Also the layout of the one and only render page is not hard coded but given as a paramter to the configuration, so that it can be implemented later, as can be seen in the examples.

-}
