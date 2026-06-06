{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DerivingStrategies #-}

module Main (main) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad.State.Strict (get, modify)
import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:), (.:?))
import qualified Data.ByteString.Lazy as LBS
import Data.List (find)
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Vector as Vec
import Network.HTTP.Simple
  ( getResponseBody
  , httpLBS
  , parseRequest
  , setRequestHeader
  )
import Numeric (showFFloat)
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.FilePath ((</>))

import qualified Brick as B
import qualified Brick.Widgets.Border as Border
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V

targetAssetName :: Text
targetAssetName = "nvim-linux-x86_64.tar.gz"

releasesUrl :: String
releasesUrl = "https://api.github.com/repos/neovim/neovim/releases?per_page=100"

nightlyUrl :: String
nightlyUrl = "https://api.github.com/repos/neovim/neovim/releases/tags/nightly"

data Name
  = StableList
  | UnstableList
  deriving stock (Eq, Ord, Show)

data Tab
  = StableTab
  | UnstableTab
  deriving stock (Eq, Show)

data AppState = AppState
  { stTab :: Tab
  , stStable :: L.List Name ReleaseItem
  , stUnstable :: L.List Name ReleaseItem
  , stStatus :: Text
  }
  deriving stock (Show)

data GHAsset = GHAsset
  { ghAssetName :: Text
  , ghAssetDownloadUrl :: Text
  , ghAssetSize :: Int
  }
  deriving stock (Show)

instance FromJSON GHAsset where
  parseJSON = withObject "GHAsset" $ \o ->
    GHAsset
      <$> o .: "name"
      <*> o .: "browser_download_url"
      <*> o .: "size"

data GHRelease = GHRelease
  { ghTagName :: Text
  , ghName :: Maybe Text
  , ghDraft :: Bool
  , ghPrerelease :: Bool
  , ghPublishedAt :: Maybe Text
  , ghAssets :: [GHAsset]
  }
  deriving stock (Show)

instance FromJSON GHRelease where
  parseJSON = withObject "GHRelease" $ \o ->
    GHRelease
      <$> o .: "tag_name"
      <*> o .:? "name"
      <*> o .: "draft"
      <*> o .: "prerelease"
      <*> o .:? "published_at"
      <*> o .: "assets"

data ReleaseItem = ReleaseItem
  { itemTag :: Text
  , itemTitle :: Text
  , itemPrerelease :: Bool
  , itemPublishedAt :: Maybe Text
  , itemAssetUrl :: Text
  , itemAssetSize :: Int
  }
  deriving stock (Eq, Show)

main :: IO ()
main = do
  initial <- initialState
  _ <- B.defaultMain app initial
  pure ()

app :: B.App AppState e Name
app =
  B.App
    { B.appDraw = drawUI
    , B.appChooseCursor = B.neverShowCursor
    , B.appHandleEvent = handleEvent
    , B.appStartEvent = pure ()
    , B.appAttrMap = const theAttrMap
    }

initialState :: IO AppState
initialState = do
  fetched <- fetchReleaseItems
  case fetched of
    Left err ->
      pure $
        AppState
          StableTab
          (mkList StableList [])
          (mkList UnstableList [])
          ("Failed to fetch releases: " <> T.pack err)
    Right (stableItems, unstableItems) ->
      pure $
        AppState
          StableTab
          (mkList StableList stableItems)
          (mkList UnstableList unstableItems)
          (statusText stableItems unstableItems)

mkList :: Name -> [ReleaseItem] -> L.List Name ReleaseItem
mkList name xs = L.list name (Vec.fromList xs) 1

drawUI :: AppState -> [B.Widget Name]
drawUI st =
  [ B.padAll 1 $
      Border.borderWithLabel (B.txt " Neovim release downloader ") $
        B.vBox
          [ B.padAll 1 (drawTabs st)
          , Border.hBorder
          , B.vLimit 20 $ L.renderList drawItem True (currentList st)
          , Border.hBorder
          , B.txt ""
          , B.txt helpText
          , B.txt ("Status: " <> stStatus st)
          ]
  ]

drawTabs :: AppState -> B.Widget Name
drawTabs st =
  B.txt $
    tabLabel StableTab "stable"
      <> "    "
      <> tabLabel UnstableTab "unstable"
 where
  tabLabel tab label
    | stTab st == tab = "[ " <> label <> " ]"
    | otherwise = "  " <> label <> "  "

drawItem :: Bool -> ReleaseItem -> B.Widget Name
drawItem selected item =
  let kind = if itemPrerelease item then "pre" else "stable"
      pub = maybe "-" (T.take 10) (itemPublishedAt item)
      line =
        T.concat
          [ itemTag item
          , "  "
          , kind
          , "  "
          , pub
          , "  "
          , sizeText (itemAssetSize item)
          , "  "
          , itemTitle item
          ]
      widget = B.txt line
   in if selected
        then B.withAttr L.listSelectedFocusedAttr widget
        else widget

helpText :: Text
helpText =
  "Keys: Tab/h/l switch tabs | j/k or Up/Down move | Enter download | r reload | q/Esc quit"

theAttrMap :: B.AttrMap
theAttrMap =
  B.attrMap
    V.defAttr
    [ (L.listSelectedAttr, V.defAttr `V.withStyle` V.reverseVideo)
    , (L.listSelectedFocusedAttr, V.defAttr `V.withStyle` V.reverseVideo)
    ]

handleEvent :: B.BrickEvent Name e -> B.EventM Name AppState ()
handleEvent (B.VtyEvent ev) =
  case ev of
    V.EvKey (V.KChar 'q') [] -> B.halt
    V.EvKey V.KEsc [] -> B.halt
    V.EvKey (V.KChar '\t') [] -> switchTab
    V.EvKey (V.KChar 'h') [] -> modify $ \s -> s{stTab = StableTab}
    V.EvKey (V.KChar 'l') [] -> modify $ \s -> s{stTab = UnstableTab}
    V.EvKey (V.KChar 'k') [] -> moveCurrent L.listMoveUp
    V.EvKey V.KUp [] -> moveCurrent L.listMoveUp
    V.EvKey (V.KChar 'j') [] -> moveCurrent L.listMoveDown
    V.EvKey V.KDown [] -> moveCurrent L.listMoveDown
    V.EvKey V.KPageUp [] -> moveCurrent (L.listMoveBy (-10))
    V.EvKey V.KPageDown [] -> moveCurrent (L.listMoveBy 10)
    V.EvKey V.KHome [] -> moveCurrent L.listMoveToBeginning
    V.EvKey V.KEnd [] -> moveCurrent L.listMoveToEnd
    V.EvKey V.KEnter [] -> downloadSelected
    V.EvKey (V.KChar 'r') [] -> reloadReleases
    _ -> pure ()
handleEvent _ = pure ()

switchTab :: B.EventM Name AppState ()
switchTab =
  modify $ \s ->
    s
      { stTab =
          case stTab s of
            StableTab -> UnstableTab
            UnstableTab -> StableTab
      }

moveCurrent :: (L.List Name ReleaseItem -> L.List Name ReleaseItem) -> B.EventM Name AppState ()
moveCurrent f =
  modify $ \s ->
    case stTab s of
      StableTab -> s{stStable = f (stStable s)}
      UnstableTab -> s{stUnstable = f (stUnstable s)}

currentList :: AppState -> L.List Name ReleaseItem
currentList s =
  case stTab s of
    StableTab -> stStable s
    UnstableTab -> stUnstable s

selectedItem :: AppState -> Maybe ReleaseItem
selectedItem s = snd <$> L.listSelectedElement (currentList s)

downloadSelected :: B.EventM Name AppState ()
downloadSelected = do
  st <- get
  case selectedItem st of
    Nothing ->
      modify $ \s -> s{stStatus = "No release selected."}
    Just item -> do
      result <- B.suspendAndResume' (downloadItem item)
      modify $ \s ->
        s
          { stStatus =
              case result of
                Left err -> "Download failed: " <> T.pack err
                Right path -> "Saved: " <> T.pack path
          }

reloadReleases :: B.EventM Name AppState ()
reloadReleases = do
  result <- B.suspendAndResume' fetchReleaseItems
  modify $ \s ->
    case result of
      Left err -> s{stStatus = "Reload failed: " <> T.pack err}
      Right (stableItems, unstableItems) ->
        s
          { stStable = mkList StableList stableItems
          , stUnstable = mkList UnstableList unstableItems
          , stStatus = statusText stableItems unstableItems
          }

statusText :: [ReleaseItem] -> [ReleaseItem] -> Text
statusText stableItems unstableItems =
  T.concat
    [ "Loaded "
    , T.pack (show (length stableItems))
    , " stable / "
    , T.pack (show (length unstableItems))
    , " unstable releases with "
    , targetAssetName
    , "."
    ]

fetchReleaseItems :: IO (Either String ([ReleaseItem], [ReleaseItem]))
fetchReleaseItems = do
  releasesResult <- fetchJson releasesUrl
  nightlyResult <- fetchJson nightlyUrl
  pure $ do
    releases <- releasesResult
    let withNightly =
          case nightlyResult of
            Right nightly -> uniqueByTag (nightly : releases)
            Left _ -> uniqueByTag releases
        usable = filter (not . ghDraft) withNightly
        stableItems = mapMaybe releaseToItem $ filter (not . ghPrerelease) usable
        unstableItems = mapMaybe releaseToItem $ filter ghPrerelease usable
    Right (stableItems, unstableItems)

uniqueByTag :: [GHRelease] -> [GHRelease]
uniqueByTag = go []
 where
  go _seen [] = []
  go seen (r : rs)
    | ghTagName r `elem` seen = go seen rs
    | otherwise = r : go (ghTagName r : seen) rs

releaseToItem :: GHRelease -> Maybe ReleaseItem
releaseToItem rel = do
  asset <- find ((== targetAssetName) . ghAssetName) (ghAssets rel)
  let tag = ghTagName rel
  pure $
    ReleaseItem
      { itemTag = tag
      , itemTitle = fromMaybe tag (ghName rel)
      , itemPrerelease = ghPrerelease rel
      , itemPublishedAt = ghPublishedAt rel
      , itemAssetUrl = ghAssetDownloadUrl asset
      , itemAssetSize = ghAssetSize asset
      }

fetchJson :: FromJSON a => String -> IO (Either String a)
fetchJson url = do
  bodyResult <- tryAny $ do
    req0 <- parseRequest url
    let req =
          setRequestHeader "User-Agent" ["nvim-release-tui"] $
            setRequestHeader "Accept" ["application/vnd.github+json"]
              req0
    getResponseBody <$> httpLBS req
  pure $ do
    body <- bodyResult
    eitherDecode body

downloadItem :: ReleaseItem -> IO (Either String FilePath)
downloadItem item =
  tryAny $ do
    home <- getHomeDirectory
    let dir = home </> "Downloads"
        path = dir </> versionedAssetFilename item
    createDirectoryIfMissing True dir
    req0 <- parseRequest (T.unpack (itemAssetUrl item))
    let req = setRequestHeader "User-Agent" ["nvim-release-tui"] req0
    response <- httpLBS req
    LBS.writeFile path (getResponseBody response)
    pure path

tryAny :: IO a -> IO (Either String a)
tryAny action = do
  result <- try action
  case result of
    Left (e :: SomeException) -> pure $ Left (displayException e)
    Right value -> pure $ Right value

versionedAssetFilename :: ReleaseItem -> FilePath
versionedAssetFilename item =
  "nvim-linux-x86_64-" <> sanitizeTag (T.unpack (itemTag item)) <> ".tar.gz"

sanitizeTag :: String -> String
sanitizeTag = map replaceBad
 where
  replaceBad c
    | c `elem` ("/\\: *?\"<>|" :: String) = '-'
    | otherwise = c

sizeText :: Int -> Text
sizeText bytes =
  T.pack (showFFloat (Just 1) mb " MB")
 where
  mb :: Double
  mb = fromIntegral bytes / (1024 * 1024)
