{-# LANGUAGE TemplateHaskell, QuasiQuotes, OverloadedStrings, TypeFamilies, MultiParamTypeClasses, Arrows #-}
module Main where

import Yesod
import Control.Concurrent (threadDelay)
import Control.Wire
import Prelude hiding ((.), id)
import Data.Map

import HWebUI

-- a double conversion function
atof :: String -> Double
atof instr = case (reads instr) of
     [] -> 0.0
     [(f, x)] -> f
      
main :: IO ()
main = do
    -- settings 
    -----------
  
    let port = 8080
        
    -- create layout 
    ----------------
        
    let guiLayout = do    
        wInitGUI port
        
        -- a table with the entry fields (as text) the operator and the result
        [whamlet|
              <H1>HWebUI - MultiSelect Example
              <p>
                    |]

        wMultiSelect "mselect" 200
        wHtml "output"

    -- create functionality 
    -----------------------
        
    let gsmap = (fromList [])::(Map String GSChannel)
        
    (mselect, gsmap) <- multiSelectW "mselect" gsmap
    (output, gsmap) <- htmlW "output" gsmap
        
    -- build the FRP wire, arrow notation, with recursion, using delay (!)
    let w1 = mselect . (once . ((pure $ Just [("one", False, "data from one"), ("two", False, "data from two"), ("three", False, "data from three"), ("four", False, "data from four")])) <|> (pure Nothing))
    let w2 = output . ((Just . (Prelude.foldl (\a b -> a ++ " " ++ (show b)) "Selected: ")) <$> id) . w1
    let theWire = w2
    
    -- run the webserver, the netwire loop and wait for termination   
    runHWebUI port gsmap guiLayout theWire

    return ()
    
    

