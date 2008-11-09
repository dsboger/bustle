{-
Bustle.Renderer: render nice Cairo diagrams from a list of D-Bus messages
Copyright (C) 2008 Collabora Ltd.

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
-}
module Bustle.Renderer
    ( process
    )
where

import Bustle.Types

import qualified Data.Set as Set
import Data.Set (Set)
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Ratio

import Control.Monad.State
import Control.Monad (forM_)

import Data.List (isPrefixOf, stripPrefix)
import Data.Maybe (fromMaybe)

import Graphics.Rendering.Cairo


process :: [Message] -> Render (Double, Double)
process log = do
    finalState <- execStateT (mapM_ munge log') initialState

    let width = Map.fold max firstAppX (coordinates finalState) + 70
    let height = row finalState + 30

    return (width, height)

  where initialState = BustleState Map.empty Map.empty 0 0 startTime
        relevant (MethodReturn {}) = True
        relevant (Error        {}) = True
        relevant m                 = path m /= "/org/freedesktop/DBus"

        log' = filter relevant log

        startTime = case log' of
            m:_ -> timestamp m
            _   -> 0

data BustleState =
    BustleState { coordinates :: Map BusName Double
                , pending :: Map (BusName, Serial) (Message, (Double, Double))
                , row :: Double
                , mostRecentLabels :: Double
                , startTime :: Milliseconds
                }

modifyCoordinates f = modify (\bs -> bs { coordinates = f (coordinates bs)})

addPending m = do
    x <- destinationCoordinate m
    y <- gets row
    let update = Map.insert (sender m, serial m) (m, (x, y))

    modify $ \bs -> bs { pending = update (pending bs) }

returnLike m@(MethodReturn {}) = True
returnLike m@(Error {})        = True
retrunLike m                   = False

findCorrespondingCall mr | returnLike mr = do
    let key = (destination mr, inReplyTo mr)
    ps <- gets pending
    case Map.lookup key ps of
        Nothing  -> return Nothing
        Just mcc -> do modify (\bs -> bs { pending = Map.delete key ps })
                       return $ Just mcc
findCorrespondingCall _ = return Nothing


advanceBy :: Double -> StateT BustleState Render ()
advanceBy d = do
    lastLabelling <- gets mostRecentLabels

    current <- gets row

    when (current - lastLabelling > 400) $ do
        xs <- gets (Map.toList . coordinates)
        forM_ xs $ \(name, x) -> lift $ do
            drawHeader name x (current + d)
        modify $ \bs -> bs { mostRecentLabels = (current + d)
                           , row = row bs + d
                           }
    current <- gets row
    modify (\bs -> bs { row = row bs + d })
    next <- gets row

    margin <- rightmostApp

    lift $ do
        moveTo 0 (current + 15)
        setSourceRGB 0.7 0.4 0.4
        setLineWidth 0.2
        lineTo (margin + 35) (current + 15)
        stroke

    lift $ do setSourceRGB 0.7 0.7 0.7
              setLineWidth 1

    xs <- gets (Map.fold (:) [] . coordinates)
    forM_ xs $ \x -> lift $ do
        moveTo x (current + 15)
        lineTo x (next + 15)
        stroke

    lift $ do setSourceRGB 0 0 0
              setLineWidth 2

abbreviateBusName :: BusName -> BusName
abbreviateBusName n@(':':_) = n
abbreviateBusName n = reverse . takeWhile (/= '.') . reverse $ n

drawHeader :: BusName -> Double -> Double -> Render ()
drawHeader name' x y = do
    let name = abbreviateBusName name'
    extents <- textExtents name
    let diff = textExtentsWidth extents / 2
    moveTo (x - diff) (y + 10)
    showText name

addApplication :: BusName -> Double -> StateT BustleState Render Double
addApplication s c = do
    currentRow <- gets row

    lift $ do drawHeader s c (currentRow - 20)

              setSourceRGB 0.7 0.7 0.7
              setLineWidth 1

              moveTo c (currentRow - 5)
              lineTo c (currentRow + 15)
              stroke

              setSourceRGB 0 0 0
              setLineWidth 2

    modifyCoordinates (Map.insert s c)
    return c

firstAppX = 400

appCoordinate :: BusName -> StateT BustleState Render Double
appCoordinate s = do
    cs <- gets coordinates
    case Map.lookup s cs of
        Just c  -> return c
        Nothing -> do c <- rightmostApp
                      addApplication s (c + 70)

rightmostApp = Map.fold max firstAppX `fmap` gets coordinates

senderCoordinate :: Message -> StateT BustleState Render Double
senderCoordinate m = appCoordinate (sender m)

destinationCoordinate :: Message -> StateT BustleState Render Double
destinationCoordinate m = appCoordinate (destination m)

abbreviate :: Interface -> Interface
abbreviate i = fromMaybe i $ stripPrefix "org.freedesktop." i

prettyPath :: ObjectPath -> ObjectPath
prettyPath p = fromMaybe p $ stripPrefix "/org/freedesktop/Telepathy/Connection/" p

memberName :: Message -> StateT BustleState Render ()
memberName m = do
    current <- gets row

    lift $ do
        moveTo 60 current
        showText . prettyPath $ path m

        moveTo 60 (current + 10)
        showText . abbreviate $ iface m ++ " . " ++ member m

relativeTimestamp :: Message -> StateT BustleState Render ()
relativeTimestamp m = do
    base <- gets startTime
    let relative = (timestamp m - base) `div` 1000
    current <- gets row
    lift $ do
        moveTo 0 current
        showText $ show relative ++ "ms"


returnArc mr callx cally = do
    destinationx <- destinationCoordinate mr
    currentx     <- senderCoordinate mr
    currenty     <- gets row

    lift $ dottyArc (destinationx > currentx) currentx currenty callx cally

munge :: Message -> StateT BustleState Render ()
munge m = case m of
        Signal {}       -> do
            advance
            relativeTimestamp m
            memberName m
            signal m

        MethodCall {}   -> do
            advance
            relativeTimestamp m
            memberName m
            methodCall m
            addPending m

        MethodReturn {} -> do
            call <- findCorrespondingCall m
            case call of
                Nothing         -> return ()
                Just (_, (x,y)) -> do
                    advance
                    relativeTimestamp m
                    methodReturn m
                    returnArc m x y

        Error {} -> do
            call <- findCorrespondingCall m
            case call of
                Nothing         -> return ()
                Just (_, (x,y)) -> do
                    advance
                    relativeTimestamp m
                    errorReturn m
                    returnArc m x y

  where advance = advanceBy 30 -- FIXME: use some function of timestamp


methodCall = methodLike True
methodReturn = methodLike False
errorReturn m = do lift $ setSourceRGB 1 0 0
                   methodLike False m
                   lift $ setSourceRGB 0 0 0

methodLike above m = do
    sc <- senderCoordinate m
    dc <- destinationCoordinate m
    t <- gets row
    lift $ halfArrow above sc dc t

signal m = do
    x <- senderCoordinate m
    t <- gets row
    cs <- gets coordinates
    let (left, right) = (Map.fold min 10000 cs, Map.fold max 0 cs)
    lift $ signalArrow x left right t


--
-- Shapes
--

halfArrowHead :: Bool -> Bool -> Render ()
halfArrowHead above left = do
    (x,y) <- getCurrentPoint
    let x' = if left then x - 10 else x + 10
    let y' = if above then y - 5 else y + 5
    if left -- work around weird artifacts
      then moveTo x' y' >> lineTo x y
      else lineTo x' y' >> moveTo x y

arrowHead :: Bool -> Render ()
arrowHead left = halfArrowHead False left >> halfArrowHead True left

halfArrow :: Bool -> Double -> Double -> Double -> Render ()
halfArrow above from to y = do
    moveTo from y
    lineTo to y
    halfArrowHead above (from < to)
    stroke

signalArrow :: Double -> Double -> Double -> Double -> Render ()
signalArrow epicentre left right y = do
    newPath
    arc epicentre y 5 0 (2 * pi)
    stroke

    moveTo (left - 20) y
    arrowHead False
    lineTo (epicentre - 5) y
    stroke

    moveTo (epicentre + 5) y
    lineTo (right + 20) y
    arrowHead True
    stroke


dottyArc :: Bool -> Double -> Double -> Double -> Double -> Render ()
dottyArc left startx starty endx endy = do
    let offset = if left then (-) else (+)

    setSourceRGB 0.4 0.7 0.4
    setDash [3, 3] 0

    moveTo startx starty
    curveTo (startx `offset` 60) (starty - 10)
            (endx   `offset` 60) (endy   + 10)
            endx endy
    stroke

    setSourceRGB 0 0 0
    setDash [] 0

-- vim: sw=2 sts=2