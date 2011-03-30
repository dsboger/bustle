{-
Bustle: a tool to draw charts of D-Bus activity
Copyright © 2008–2011 Collabora Ltd.

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
{-# LANGUAGE ScopedTypeVariables, FlexibleInstances #-}
module Main (main)
where

import Prelude hiding (catch)

import Control.Exception
import Control.Monad (when)
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Error

import Data.Maybe (isJust, isNothing, fromJust)
import Data.Version (showVersion)

import Paths_bustle
import Bustle.Application.Monad
import Bustle.Parser
import Bustle.Renderer (process)
import Bustle.Types
import Bustle.Diagram
import Bustle.Upgrade (upgrade)
import Bustle.Util
import Bustle.StatisticsPane

import System.Glib.GError (GError(..), catchGError)

import Graphics.UI.Gtk
import Graphics.UI.Gtk.Glade

import Graphics.Rendering.Cairo (withPDFSurface, renderWith)

import System.Environment (getArgs)
import System.FilePath (splitFileName, dropExtension)

type B a = Bustle BConfig BState a

type Details = (FilePath, String, Diagram)
data WindowInfo =
    WindowInfo { wiWindow :: Window
               , wiSave :: ImageMenuItem
               , wiViewStatistics :: CheckMenuItem
               , wiNotebook :: Notebook
               , wiStatsBook :: Notebook
               , wiStatsPane :: StatsPane
               , wiLayout :: Layout
               }

data BConfig =
    BConfig { debugEnabled :: Bool
            , bustleIcon :: Maybe Pixbuf
            , methodIcon :: Maybe Pixbuf
            , signalIcon :: Maybe Pixbuf
            }

data BState = BState { windows :: Int
                     , initialWindow :: Maybe WindowInfo
                     }

modifyWindows :: (Int -> Int) -> B ()
modifyWindows f = modify $ \s -> s { windows = f (windows s) }

incWindows :: B ()
incWindows = modifyWindows (+1)

decWindows :: B Int
decWindows = modifyWindows (subtract 1) >> gets windows

main :: IO ()
main = do
    initGUI

    -- FIXME: get a real option parser
    args <- getArgs
    let debug = any isDebug args

    [bustle, method, signal] <- mapM loadPixbuf
        ["bustle.png", "dfeet-method.png", "dfeet-signal.png"]

    let config = BConfig { debugEnabled = debug
                         , bustleIcon = bustle
                         , methodIcon = method
                         , signalIcon = signal
                         }
        initialState = BState { windows = 0
                              , initialWindow = Nothing
                              }

    runB config initialState $ mainB (filter (not . isDebug) args)
  where
    isDebug = (== "--debug")

mainB :: [String] -> B ()
mainB args = do
  case args of
      ["--pair", sessionLogFile, systemLogFile] ->
          loadLog sessionLogFile (Just systemLogFile)
      _ -> mapM_ (\file -> loadLog file Nothing) args

  -- If no windows are open (because none of the arguments, if any, were loaded
  -- successfully) create an empty window
  n <- gets windows
  when (n == 0) createInitialWindow

  io mainGUI

createInitialWindow :: B ()
createInitialWindow = do
  misc <- emptyWindow
  modify $ \s -> s { initialWindow = Just misc }

loadInInitialWindow :: FilePath -> Maybe FilePath -> B ()
loadInInitialWindow = loadLogWith consumeInitialWindow
  where consumeInitialWindow = do
          x <- gets initialWindow
          case x of
            Nothing   -> emptyWindow
            Just misc -> do
              modify $ \s -> s { initialWindow = Nothing }
              return misc

loadLog :: FilePath -> Maybe FilePath -> B ()
loadLog = loadLogWith emptyWindow

-- Displays a modal error dialog, with the given strings as title and body
-- respectively.
displayError :: String -> String -> IO ()
displayError title body = do
  dialog <- messageDialogNew Nothing [DialogModal] MessageError ButtonsClose title
  messageDialogSetSecondaryText dialog body
  dialog `afterResponse` \_ -> widgetDestroy dialog
  widgetShowAll dialog

-- This needs FlexibleInstances and I don't know why. It's also an orphan
-- instance, which is distressing.
instance Error (String, String) where
    strMsg s = ("", s)
    noMsg = ("", "")

loadLogWith :: B WindowInfo   -- ^ action returning a window to load the log(s) in
            -> FilePath       -- ^ a log file to load and display
            -> Maybe FilePath -- ^ an optional second log to show alongside the
                              --   first log.
            -> B ()
loadLogWith getWindow session maybeSystem = do
    ret <- runErrorT $ do
        sessionMessages <- readLogFile session
        systemMessages <- case maybeSystem of
            Just system -> readLogFile system
            Nothing     -> return []

        -- FIXME: pass the log file name into the renderer
        let ((xTranslation, shapes), ws) =
                process (upgrade sessionMessages)
                        (upgrade systemMessages)
        forM_ ws $ io . warn

        windowInfo <- lift getWindow
        lift $ displayLog windowInfo session maybeSystem xTranslation shapes
                          sessionMessages systemMessages

    case ret of
      Left (f, e) -> io $ displayError ("Could not read '" ++ f ++ "'") e
      Right () -> return ()

  where readLogFile f = do
            input <- handleIOExceptions (\e -> (f, show e)) $ readFile f
            toErrorT (\e -> (f, "Parse error " ++ show e)) $ readLog input


maybeQuit :: B ()
maybeQuit = do
  n <- decWindows
  when (n == 0) (io mainQuit)

emptyWindow :: B WindowInfo
emptyWindow = do
  Just xml <- io $ xmlNew =<< getDataFileName "bustle.glade"

  -- Grab a bunch of widgets. Surely there must be a better way to do this?
  let getW cast name = io $ xmlGetWidget xml cast name

  window <- getW castToWindow "diagramWindow"
  [openItem, saveItem, closeItem, aboutItem] <- mapM (getW castToImageMenuItem)
       ["open", "saveAs", "close", "about"]
  openTwoItem <- getW castToMenuItem "openTwo"
  viewStatistics <- getW castToCheckMenuItem "statistics"
  layout <- getW castToLayout "diagramLayout"
  [nb, statsBook] <- mapM (getW castToNotebook)
      ["notebook", "statsBook"]

  -- Open two logs dialog widgets
  openTwoDialog <- getW castToDialog "openTwoDialog"
  [sessionBusChooser, systemBusChooser] <- mapM (getW castToFileChooserButton)
      ["sessionBusChooser", "systemBusChooser"]

  -- Set up the window itself
  withProgramIcon (windowSetIcon window)
  embedIO $ onDestroy window . makeCallback maybeQuit

  -- File menu
  embedIO $ onActivateLeaf openItem . makeCallback (openDialogue window)
  io $ openTwoItem `onActivateLeaf` widgetShowAll openTwoDialog
  io $ closeItem `onActivateLeaf` widgetDestroy window

  -- Help menu
  embedIO $ onActivateLeaf aboutItem . makeCallback (showAbout window)

  -- Diagram area panning
  io $ do
    hadj <- layoutGetHAdjustment layout
    vadj <- layoutGetVAdjustment layout

    window `on` keyPressEvent $ tryEvent $ do
      key <- eventKeyName
      case key of
        "Up"        -> io $ decStep vadj
        "Down"      -> io $ incStep vadj
        "Left"      -> io $ decStep hadj
        "Right"     -> io $ incStep hadj
        "Page_Down" -> io $ incPage vadj
        "space"     -> io $ incPage vadj
        "Page_Up"   -> io $ decPage vadj
        _           -> stopEvent

  -- Open two logs dialog
  withProgramIcon (windowSetIcon openTwoDialog)

  io $ do
    windowSetTransientFor openTwoDialog window
    openTwoDialog `on` deleteEvent $ tryEvent $ io $ widgetHide openTwoDialog

    -- Keep the two dialogs' current folders in sync. We only propagate when
    -- the new dialog doesn't have a current file. Otherwise, choosing a file
    -- from a different directory in the second chooser unselects the first.
    let propagateCurrentFolder d1 d2 = do
            d1 `onCurrentFolderChanged` do
                f1 <- fileChooserGetCurrentFolder d1
                f2 <- fileChooserGetCurrentFolder d2
                otherFile <- fileChooserGetFilename d2
                when (isNothing otherFile && f1 /= f2 && isJust f1) $ do
                    fileChooserSetCurrentFolder d2 (fromJust f1)
                    return ()

    propagateCurrentFolder sessionBusChooser systemBusChooser
    propagateCurrentFolder systemBusChooser sessionBusChooser

  let hideTwoDialog = do
          widgetHideAll openTwoDialog
          fileChooserUnselectAll sessionBusChooser
          fileChooserUnselectAll systemBusChooser

  embedIO $ \r -> openTwoDialog `afterResponse` \resp -> do
      -- The "Open" button should only be sensitive if both pickers have a
      -- file in them, but the GtkFileChooserButton:file-set signal is not
      -- bound in my version of Gtk2Hs. So yeah...
      if (resp == ResponseAccept)
        then do
          sessionLogFile <- fileChooserGetFilename sessionBusChooser
          systemLogFile <- fileChooserGetFilename systemBusChooser

          case (sessionLogFile, systemLogFile) of
            (Just f1, Just f2) -> do
                makeCallback (loadInInitialWindow f1 (Just f2)) r
                hideTwoDialog
            _ -> return ()
        else
          hideTwoDialog

  m <- asks methodIcon
  s <- asks signalIcon
  statsPane <- io $ statsPaneNew xml m s

  let windowInfo = WindowInfo { wiWindow = window
                              , wiSave = saveItem
                              , wiViewStatistics = viewStatistics
                              , wiNotebook = nb
                              , wiStatsBook = statsBook
                              , wiStatsPane = statsPane
                              , wiLayout = layout
                              }

  incWindows
  io $ widgetShowAll window
  return windowInfo

displayLog :: WindowInfo
           -> FilePath
           -> Maybe FilePath
           -> Double
           -> Diagram
           -> Log
           -> Log
           -> B ()
displayLog (WindowInfo { wiWindow = window
                       , wiSave = saveItem
                       , wiViewStatistics = viewStatistics
                       , wiLayout = layout
                       , wiNotebook = nb
                       , wiStatsBook = statsBook
                       , wiStatsPane = statsPane
                       })
           sessionPath
           maybeSystemPath
           xTranslation
           shapes
           sessionMessages
           systemMessages = do
  let (width, height) = diagramDimensions shapes
      (directory, sessionName) = splitFileName sessionPath
      baseName = snd . splitFileName
      title = maybe sessionName
                    ((++ (" + " ++ sessionName)) . baseName)
                    maybeSystemPath
      details = (directory, title, shapes)

  showBounds <- asks debugEnabled

  io $ do
    windowSetTitle window $ title ++ " — D-Bus Sequence Diagram"
    widgetSetSensitivity saveItem True
    onActivateLeaf saveItem $ saveToPDFDialogue window details

    layoutSetSize layout (floor width) (floor height)
    -- I think we could speed things up by only showing the revealed area
    -- rather than everything that's visible.
    layout `on` exposeEvent $ tryEvent $ io $ update layout shapes showBounds

    notebookSetCurrentPage nb 1

    -- Shift to make the timestamp column visible
    hadj <- layoutGetHAdjustment layout
    (windowWidth, _) <- windowGetSize window
    -- Roughly centre the timestamp-and-member column
    adjustmentSetValue hadj
        (xTranslation -
            (fromIntegral windowWidth - timestampAndMemberWidth) / 2
        )

    statsPaneSetMessages statsPane sessionMessages systemMessages

    widgetSetSensitivity viewStatistics True
    -- the version of gtk2hs I'm using has a checkMenuItemToggled which is a
    -- method not a signal.
    connectGeneric "toggled" False viewStatistics $ do
        active <- checkMenuItemGetActive viewStatistics
        if active
            then widgetShow statsBook
            else widgetHide statsBook

    -- The stats start off hidden.
    widgetHide statsBook

  return ()

update :: Layout -> Diagram -> Bool -> IO ()
update layout shapes showBounds = do
  win <- layoutGetDrawWindow layout

  hadj <- layoutGetHAdjustment layout
  hpos <- adjustmentGetValue hadj
  hpage <- adjustmentGetPageSize hadj

  vadj <- layoutGetVAdjustment layout
  vpos <- adjustmentGetValue vadj
  vpage <- adjustmentGetPageSize vadj

  let r = (hpos, vpos, hpos + hpage, vpos + vpage)

  renderWithDrawable win $ drawRegion r showBounds shapes

-- Add/remove one step/page increment from an Adjustment, limited to the top of
-- the last page.
incStep, decStep, incPage, decPage :: Adjustment -> IO ()
incStep = incdec (+) adjustmentGetStepIncrement
decStep = incdec (-) adjustmentGetStepIncrement
incPage = incdec (+) adjustmentGetPageIncrement
decPage = incdec (-) adjustmentGetPageIncrement

incdec :: (Double -> Double -> Double) -- How to combine the increment
       -> (Adjustment -> IO Double)    -- Action to discover the increment
       -> Adjustment
       -> IO ()
incdec (+-) f adj = do
    pos <- adjustmentGetValue adj
    step <- f adj
    page <- adjustmentGetPageSize adj
    lim <- adjustmentGetUpper adj
    adjustmentSetValue adj $ min (pos +- step) (lim - page)

withProgramIcon :: (Maybe Pixbuf -> IO ()) -> B ()
withProgramIcon f = asks bustleIcon >>= io . f

loadPixbuf :: FilePath -> IO (Maybe Pixbuf)
loadPixbuf filename = do
  iconName <- getDataFileName filename
  (fmap Just (pixbufNewFromFile iconName)) `catchGError`
    \(GError _ _ msg) -> warn msg >> return Nothing

openDialogue :: Window -> B ()
openDialogue window = embedIO $ \r -> do
  chooser <- fileChooserDialogNew Nothing (Just window) FileChooserActionOpen
             [ ("gtk-cancel", ResponseCancel)
             , ("gtk-open", ResponseAccept)
             ]
  chooser `set` [ windowModal := True
                , fileChooserLocalOnly := True
                ]

  chooser `afterResponse` \resp -> do
      when (resp == ResponseAccept) $ do
          Just fn <- fileChooserGetFilename chooser
          makeCallback (loadInInitialWindow fn Nothing) r
      widgetDestroy chooser

  widgetShowAll chooser

saveToPDFDialogue :: Window -> Details -> IO ()
saveToPDFDialogue window (directory, filename, shapes) = do
  chooser <- fileChooserDialogNew Nothing (Just window) FileChooserActionSave
             [ ("gtk-cancel", ResponseCancel)
             , ("gtk-save", ResponseAccept)
             ]
  chooser `set` [ windowModal := True
                , fileChooserLocalOnly := True
                , fileChooserDoOverwriteConfirmation := True
                ]

  fileChooserSetCurrentFolder chooser directory
  fileChooserSetCurrentName chooser $ filename ++ ".pdf"

  chooser `afterResponse` \resp -> do
      when (resp == ResponseAccept) $ do
          Just fn <- io $ fileChooserGetFilename chooser
          let (width, height) = diagramDimensions shapes
          withPDFSurface fn width height $
            \surface -> renderWith surface $ drawDiagram False shapes
      widgetDestroy chooser

  widgetShowAll chooser

showAbout :: Window -> B ()
showAbout window = withProgramIcon $ \icon -> io $ do
    dialog <- aboutDialogNew

    license <- (Just `fmap` (readFile =<< getDataFileName "LICENSE"))
               `catch` (\e -> warn (show (e :: IOException)) >> return Nothing)

    dialog `set` [ aboutDialogName := "Bustle"
                 , aboutDialogVersion := showVersion version
                 , aboutDialogComments := "Someone's favourite D-Bus profiler"
                 , aboutDialogWebsite := "http://willthompson.co.uk/bustle"
                 , aboutDialogAuthors := authors
                 , aboutDialogCopyright := "© 2008–2011 Collabora Ltd."
                 , aboutDialogLicense := license
                 ]
    dialog `afterResponse` \resp ->
        when (resp == ResponseCancel) (widgetDestroy dialog)
    windowSetTransientFor dialog window
    windowSetModal dialog True
    aboutDialogSetLogo dialog icon

    widgetShowAll dialog

authors :: [String]
authors = [ "Will Thompson <will.thompson@collabora.co.uk>"
          , "Dafydd Harries"
          , "Chris Lamb"
          , "Marc Kleine-Budde"
          ]

-- vim: sw=2 sts=2
