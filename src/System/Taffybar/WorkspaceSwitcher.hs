-----------------------------------------------------------------------------
-- |
-- Module      : System.Taffybar.WorkspaceSwitcher
-- Copyright   : (c) José A. Romero L.
-- License     : BSD3-style (see LICENSE)
--
-- Maintainer  : José A. Romero L. <escherdragon@gmail.com>
-- Stability   : unstable
-- Portability : unportable
--
-- Composite widget that displays all currently configured workspaces and
-- allows to switch to any of them by clicking on its label. Supports also
-- urgency hints and (with an additional hook) display of other visible
-- workspaces besides the active one (in Xinerama or XRandR installations).
--
-- N.B. If you're just looking for a drop-in replacement for the
-- "System.Taffybar.XMonadLog" widget that is clickable and doesn't require
-- DBus, you may want to see first "System.Taffybar.TaffyPager".
--
-----------------------------------------------------------------------------

module System.Taffybar.WorkspaceSwitcher (
  -- * Usage
  -- $usage
  wspaceSwitcherNew
) where

import Control.Monad
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.IORef
import Data.List ((\\))
import Data.Maybe (listToMaybe)
import Graphics.UI.Gtk
import Graphics.UI.Gtk.Gdk.Pixbuf (Pixbuf)
import Graphics.X11.Xlib.Extras

import System.Taffybar.Pager
import System.Information.EWMHDesktopInfo

type Desktop = [Workspace]

-- | Workspace record with ws name and widgets
data Workspace = Workspace
  { wsName      :: String -- ^ Name of the workspace.
  , wsLabel     :: Label  -- ^ Text widget displaying workspace markup.
  , wsImage     :: Image  -- ^ Image widget displaying the workspace image.
  , wsContainer :: Container -- ^ Container holding label/image
  }

-- $usage
-- Display clickable workspace labels and images based on window title/class.
--
-- This widget requires that the EwmhDesktops hook from the XMonadContrib
-- project be installed in your @xmonad.hs@ file:
--
-- > import XMonad.Hooks.EwmhDesktops (ewmh)
-- > main = do
-- >   xmonad $ ewmh $ defaultConfig
-- > ...
--
-- Urgency hooks are not required for the urgency hints displaying to work
-- (since it is also based on desktop events), but if you use @focusUrgent@
-- you may want to keep the \"@withUrgencyHook NoUrgencyHook@\" anyway.
--
-- Unfortunately, in multiple monitor installations EWMH does not provide a
-- way to determine what desktops are shown in secondary displays. Thus, if
-- you have more than one monitor you may want to additionally install the
-- "System.Taffybar.Hooks.PagerHints" hook in your @xmonad.hs@:
--
-- > import System.Taffybar.Hooks.PagerHints (pagerHints)
-- > main = do
-- >   xmonad $ ewmh $ pagerHints $ defaultConfig
-- > ...
--
-- Once you've properly configured @xmonad.hs@, you can use the widget in
-- your @taffybar.hs@ file:
--
-- > import System.Taffybar.WorkspaceSwitcher
-- > main = do
-- >   pager <- pagerNew defaultPagerConfig
-- >   let wss = wspaceSwitcherNew pager
--
-- now you can use @wss@ as any other Taffybar widget.

getWs :: Desktop -> Int -> Workspace
getWs = (!!)

-- | Create a new WorkspaceSwitcher widget that will use the given Pager as
-- its source of events.
wspaceSwitcherNew :: Pager -> IO Widget
wspaceSwitcherNew pager = do
  desktop <- getDesktop (config pager)
  widget  <- assembleWidget (config pager) desktop
  idxRef  <- newIORef []
  let cfg = config pager
      activecb = activeCallback cfg desktop idxRef
      urgentcb = urgentCallback cfg desktop
  subscribe pager activecb "_NET_CURRENT_DESKTOP"
  subscribe pager urgentcb "WM_HINTS"
  return widget

-- | Get workspace names from EWMH, and return a list of Workspaces.
getDesktop :: PagerConfig -> IO Desktop
getDesktop cfg = do
  names <- withDefaultCtx getWorkspaceNames
  mapM (\(name, index) -> createWorkspace cfg name index) $ zip names [0..]

clickBox :: WidgetClass w => w -> IO () -> IO Container
clickBox w act = do
  ebox <- eventBoxNew
  containerAdd ebox w
  on ebox buttonPressEvent $ liftIO act >> return True
  return $ toContainer ebox

-- | Create a workspace
createWorkspace :: PagerConfig -> String -> Int -> IO Workspace
createWorkspace cfg name index = do
  label <- labelNew Nothing
  labelSetMarkup label $ hiddenWorkspace cfg name
  image <- imageNew

  hbox <- hBoxNew False 0
  containerAdd hbox label
  containerAdd hbox image

  container <- wrapWsButton cfg =<< clickBox hbox (switch index)

  return $ Workspace { wsName = name
                     , wsLabel = label
                     , wsImage = image
                     , wsContainer = container
                     }

-- | Build the graphical representation of the widget.
assembleWidget :: PagerConfig -> Desktop -> IO Widget
assembleWidget cfg desktop = do
  hbox <- hBoxNew False (wsButtonSpacing cfg)
  mapM_ (containerAdd hbox) $ map wsContainer desktop
  widgetShowAll hbox
  return $ toWidget hbox

-- | Build a suitable callback function that can be registered as Listener
-- of "_NET_CURRENT_DESKTOP" standard events. It will track the position of
-- the active workspace in the desktop.
activeCallback :: PagerConfig -> Desktop -> IORef [Int] -> Event -> IO ()
activeCallback cfg desktop ref _ = do
  prev <- readIORef ref
  curr <- withDefaultCtx getVisibleWorkspaces
  transition cfg desktop prev curr
  writeIORef ref curr

-- | Build a suitable callback function that can be registered as Listener
-- of "WM_HINTS" standard events. It will display in a different color any
-- workspace (other than the active one) containing one or more windows
-- with its urgency hint set.
urgentCallback :: PagerConfig -> Desktop -> Event -> IO ()
urgentCallback cfg desktop event = withDefaultCtx $ do
  let window = ev_window event
  isUrgent <- isWindowUrgent window
  when isUrgent $ do
    this <- getCurrentWorkspace
    that <- getWorkspace window
    when (this /= that) $ do
      liftIO $ mark desktop (urgentWorkspace cfg) that

fst3 (x,_,_) = x

-- | Get the title and class of the first window in a given workspace.
getWorkspaceWindow :: [(Int, String, String)] -- ^ full window list
                   -> Int -- ^ Workspace
                   -> Maybe (String, String) -- ^ (window title, window class)
getWorkspaceWindow wins ws = case win of
                              Just (ws, wtitle, wclass) -> Just (wtitle, wclass)
                              Nothing -> Nothing
  where win = listToMaybe $ filter ((==ws).fst3) wins

getDesktopSummary :: Desktop -> IO ([(Int, Maybe (String, String))])
getDesktopSummary desktop = do
  allWins <- withDefaultCtx $ getWindowHandles
  let allX11Wins = map snd allWins
      allProps = map fst allWins
  wsWins <- withDefaultCtx $ mapM getWorkspace allX11Wins
  let allWs = allWorkspaces desktop
      wsProps = map (getWorkspaceWindow allProps) allWs
  return $ zip allWs wsProps

allWorkspaces :: Desktop -> [Int]
allWorkspaces desktop = [0 .. length desktop - 1]

nonEmptyWorkspaces :: IO [Int]
nonEmptyWorkspaces = withDefaultCtx $ mapM getWorkspace =<< getWindows

-- | Perform all changes needed whenever the active workspace changes.
transition :: PagerConfig -- ^ Configuration settings.
           -> Desktop -- ^ All available Labels with their default values.
           -> [Int] -- ^ Previously visible workspaces (first was active).
           -> [Int] -- ^ Currently visible workspaces (first is active).
           -> IO ()
transition cfg desktop prev curr = do
  withDefaultCtx $ do
    summary <- liftIO $ getDesktopSummary desktop
    curTitle <- getActiveWindowTitle
    curClass <- getActiveWindowClass
    liftIO $ applyImages cfg desktop (head curr) curTitle curClass summary

  let all = allWorkspaces desktop
  nonEmpty <- fmap (filter (>=0)) $ nonEmptyWorkspaces
  let empty = (all \\ nonEmpty)

  mapM_ (mark desktop $ hiddenWorkspace cfg) nonEmpty
  mapM_ (mark desktop $ emptyWorkspace cfg) empty
  mark desktop (activeWorkspace cfg) (head curr)
  mapM_ (mark desktop $ visibleWorkspace cfg) (tail curr)

applyImages :: PagerConfig
            -> Desktop
            -> Int
            -> String
            -> String
            -> [(Int, Maybe (String, String))]
            -> IO ()
applyImages cfg desktop curWs curTitle curClass summary = do
  mapM apply summary
  return ()
  where getImg (ws, props) = imageSelector cfg $ if ws == curWs
                                                 then Just (curTitle, curClass)
                                                 else props
        apply (ws, props) = do
          markImg desktop (getImg (ws, props)) ws

markImg :: Desktop -> Maybe Pixbuf -> Int -> IO ()
markImg desktop image idx = do
  let ws = getWs desktop idx
  postGUIAsync $ case image of
    Just pixbuf -> imageSetFromPixbuf (wsImage ws) pixbuf
    Nothing -> imageClear (wsImage ws)

-- | Apply the given marking function to the Label of the workspace with
-- the given index.
mark :: Desktop -- ^ List of all available workspaces.
     -> (String -> Markup) -- ^ Marking function.
     -> Int -- ^ Index of the Label to modify.
     -> IO ()
mark desktop decorate idx = do
  let ws = getWs desktop idx
  postGUIAsync $ labelSetMarkup (wsLabel ws) $ decorate $ wsName ws

-- | Switch to the workspace with the given index.
switch :: Int -> IO ()
switch idx = liftIO $ withDefaultCtx $ switchToWorkspace idx
