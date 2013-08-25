------------------------------------------------------------------------------
-- | Main module.  Exposes the SDL main function, which sets up the game loop
-- and pushes events into the Netwire session.
module Main (main, sdlMain) where

import Game.Prelude
------------------------------------------------------------------------------
import qualified Control.Wire as Wire
{-import qualified Game.Direction as Direction-}
import qualified Game.Events as Events
import qualified Game.Sprite as Sprite
import qualified Graphics.UI.SDL as SDL
------------------------------------------------------------------------------
import Control.Wire (MonadRandom, Session, Time, Wire, for, (-->))
{-import Game.Direction (Direction)-}
import Game.Sprite (Sprite, position)
import Graphics.UI.SDL (Event, Surface)


------------------------------------------------------------------------------
pixel :: Int
pixel = 4


------------------------------------------------------------------------------
-- | The real main function.  Sets up SDL and starts the game.
sdlMain :: IO ()
sdlMain = SDL.withInit [SDL.InitVideo] $ do
    screen <- uncurry SDL.setVideoMode (scale (256, 160)) 0 [SDL.HWSurface]
    SDL.rawSetCaption (Just "Vicarious") Nothing

    back <- Sprite.load "road/background"
    bgt  <- Sprite.load "road/tape"
    on   <- Sprite.load "road/background/light"
    off  <- Sprite.load "road/background/dark"

    p1 <- Sprite.load "road/paramedic/1"
    pt <- Sprite.load "road/paramedic/2"
    p2 <- Sprite.load "road/paramedic/3"

    let gmove = map . Sprite.move $ scale (134, 72)
    ghost <- gmove $ Sprite.load "road/ghost"
    let gload m a n = forM ([1..n] :: [Int]) $
            m . Sprite.load . (("road/" <> a <> "/") <>) . show

    fadea <- gload gmove "ghost" 8

    let rmove = map . Sprite.move $ scale (134, 37)
    roda  <- gload rmove "get" 6
    casta <- gload rmove "cast" 10
    gp <- rmove $ Sprite.load "road/pause"
    gc <- rmove $ Sprite.load "road/in"
    gy <- rmove $ Sprite.load "road/pull"

    let bg     = Background back on off bgt
        medic  = Paramedic p1 pt p2
        start  = Game ghost
        assets = Assets bg medic $ Ghost fadea roda casta gp gc gy

    render screen [bgt, on, p1, back]

    void $ flip runStateT start $
        eventLoop screen (gameWire assets) Wire.clockSession
  where scale = twimap (* pixel)

foreign export ccall sdlMain :: IO ()


------------------------------------------------------------------------------
data Game = Game
    { gplayer  :: Sprite
    }

player :: Lens' Game Sprite
player f game = map (\g -> game { gplayer = g }) $ f (gplayer game)

{-arrows :: Lens' Game Direction-}
{-arrows f game = map (\a -> game { garrows = a }) $ f (garrows game)-}


------------------------------------------------------------------------------
data Assets = Assets Background Paramedic Ghost


------------------------------------------------------------------------------
data Ghost = Ghost
    { fade  :: [Sprite]
    , rod   :: [Sprite]
    , cast  :: [Sprite]
    , pause :: Sprite
    , cast' :: Sprite
    , yank  :: Sprite
    }


------------------------------------------------------------------------------
data Background = Background
    { static :: Sprite
    , light  :: Sprite
    , dark   :: Sprite
    , tape   :: Sprite
    }


------------------------------------------------------------------------------
data Paramedic = Paramedic
    { para1 :: Sprite
    , paraT :: Sprite
    , para2 :: Sprite
    }


------------------------------------------------------------------------------
eventLoop :: Surface -> Wire () IO (Event, Game) ([Sprite], Game)
          -> Session IO -> StateT Game IO ()
eventLoop screen wire session = do
    event <- lift SDL.pollEvent
    (result, wire', session') <- get >>=
        lift . Wire.stepSession wire session . (event,)
    flip (either return) result $ \(sprites, game) -> do
        put game
        lift $ render screen sprites
        eventLoop screen wire' session'


------------------------------------------------------------------------------
render :: Surface -> [Sprite] -> IO ()
render screen sprites = do
    mapM_ (Sprite.draw screen) $ reverse sprites
    SDL.flip screen


------------------------------------------------------------------------------
gameWire :: Assets -> Wire () IO (Event, Game) ([Sprite], Game)
gameWire (Assets bg p ghost) = Wire.until (Events.isQuit . fst) >>>
    (\(s, g) ss -> (tape bg : maybeToList s <> ss, g)) <$> ghostWire ghost <*> flatten
        [ shadowWire (light bg) (dark bg)
        , paramedicWire p
        , pure $ static bg
        ]
  where
    flatten = flip foldr (pure []) $ (<*>) . (<$>) (:)


------------------------------------------------------------------------------
ghostWire :: Ghost -> Wire () IO (Event, Game) (Maybe Sprite, Game)
ghostWire ghost = first (pure Nothing) . Wire.until (Events.isSpace . fst) -->
    first (Just <$> wireFrames 0.2 (fade ghost)) --> chill . for 2 -->
    (Wire.until (\(_, g) -> g^.player.position._2 <= 37 * pixel) >>>
        Wire.hold_ flyUp <|> chill) -->
    chill . Wire.until (Events.isSpace . fst) -->
    first (Just <$> wireFrames 0.05 (rod ghost)) -->
    gsprite pause . for 1 -->
    first (Just <$> wireFrames 0.05 (cast ghost)) -->
    wireForever (fishWire ghost)
  where
    sarr = arr . (. snd)
    chill = sarr (\g -> (Just $ g^.player, g))
    flyUp = sarr (\g -> let g' = player %~ Sprite.move (0, -pixel) $ g
        in (Just $ g'^.player, g')) . Wire.periodically 0.1
    glift = pure . Just
    gsprite f = first $ glift (f ghost)


------------------------------------------------------------------------------
fishWire :: Ghost -> Wire () IO (Event, Game) (Maybe Sprite, Game)
fishWire ghost = (.) (first fishAnim) id
    {-first (Wire.perform . arr (maybe (return ()) print . Events.mouseMove))-}
  where
    flift f = pure . Just $ f ghost
    fishAnim = flift cast' . Wire.wackelkontaktM 0.95 --> flift yank . for 0.1


------------------------------------------------------------------------------
shadowWire :: Sprite -> Sprite -> Wire () IO a Sprite
shadowWire on off = wireForever $
    pure on . forRM (15, 25) --> flicker . forRM (0.1, 0.6)
   where flicker = wireForever $ pure off . for 0.1 --> pure on . for 0.1


------------------------------------------------------------------------------
paramedicWire :: Paramedic -> Wire () IO a Sprite
paramedicWire Paramedic { para1 = p1, paraT = pt, para2 = p2 } =
    wireForever $ thenTransition p1 --> thenTransition p2
  where thenTransition p = pure p . forRM (8, 12) --> pure pt . for 1


------------------------------------------------------------------------------
-- | Produces each sprite for the given amount of time, then inhibits.
wireFrames :: Time -> [Sprite] -> Wire () IO a Sprite
wireFrames _ []       = empty
wireFrames t (s : ss) =
    (fromJust <$> Wire.until isNothing <<<) . Wire.hold (Just s) $
    (Just <$> Wire.list ss --> pure Nothing) . Wire.periodically t


------------------------------------------------------------------------------
-- | Causes the wire to restart when it inhibits.
wireForever :: Monad m => Wire e m a b -> Wire e m a b
wireForever = fix . (-->)


------------------------------------------------------------------------------
-- | Produces for a random amount within the given range, then inhibits.
forRM :: (MonadRandom m, Monoid e) => (Time, Time) -> Wire e m a a
forRM r = id &&& Wire.noiseRM . pure r >>> Wire.mkState 0 stf
  where
    stf dt ((input, endTime), et) = let et' = et + dt in
        (if et' >= endTime then Left mempty else Right input, et')



------------------------------------------------------------------------------
{-update :: Time -> (Event, Game) -> (Either () [Sprite], Game)-}
{-update dt (event, game) = if Events.isQuit event-}
    {-then (Left (), game) else lmap Right $ update' dt event game-}


------------------------------------------------------------------------------
{-update' :: Time -> Event -> Game -> ([Sprite], Game)-}
{-update' _ event game =-}
    {-(sprites, set arrows arrows' . set player player' $ game)-}
  {-where-}
    {-arrows' = game^.arrows <> Events.direction event-}
    {-player' = Sprite.move (Direction.movement 3 arrows') $ game^.player-}
    {-back    = background game-}
    {-sprites = [static back, light back, player']-}


------------------------------------------------------------------------------
-- | Cabal doesn't seem to pass -no-hs-main to GHC.  This whole function
-- should be removed once this problem is resolved.
main :: IO ()
main = return ()

