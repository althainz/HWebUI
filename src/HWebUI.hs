{- | HWebUI is providing FRP-based GUI functionality for Haskell by utilizing the Web-Browser. It is build on top of Yesod for the Web technologies and on netwire for the FRP interface. The status is \"early prototype\". The implementation uses a Javascript library (Dojo toolkit) for providing typical widgets, HTML for the layout of the widgets. With Javascript and websockets events are transferred between the Web and the Haskell world. This happens behind the scenes. The Haskell programmer is using a FRP based interface. See also: <http://www.github.com/frankfurt-haskell-user-group/HWebUI>.
-}
module HWebUI(
  
  module Widgets,
  module Wires,
  
  -- * Running the GUI
  
  -- ** How to run the GUI
  -- $rungui
  
  -- ** Functions to run the GUI  
  runHWebUI,
  
  -- * Implementation Details
  module Messaging,
  module Server,
  
  ) where

import Yesod
import System.IO (hFlush, stdout)
import Prelude hiding ((.), id)
import Control.Wire
import Data.Map

import Messaging
import Widgets
import Server
import Wires
import Control.Monad.State
import Data.Map

-- | this function runs the HWebUI web server (the Yesod server), runs the netwire loop and wait for termination
runHWebUI port guiLayout channelStateWire = do
    -- create netwire gui elements
    let gsmap = Data.Map.fromList [] :: Map String GSChannel
    (theWire,gsmap') <- runStateT channelStateWire gsmap    
    runHWebUIServer port gsmap' guiLayout
    loopHWebUIWire theWire
    waitForHWebUIServer


{- $rungui
  
To run a GUI built with HWebUI, the background webserver needs to be started, which handels the websocket communication with the webbrowser. In addition a loop needs to be called, to run the netwire FRP based GUI api. All this is done by calling the runHWebUI function as shown below.

>    -- run the webserver, the netwire loop and wait for termination   
>    runHWebUI port gsmap guiLayout theWire
-}





