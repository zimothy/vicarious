------------------------------------------------------------------------------
-- | Defines a pure monad for the game's pure core to run in.
module Game.Monad
    (
    -- * Monads
      GameM
    , GameMT

    -- * Running
    , runGameMT
    , liftGameM

    -- * Useful actions
    , tick
    ) where

import Game.Prelude
------------------------------------------------------------------------------
import Control.Wire
import Data.Functor.Identity (Identity (..))
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)


------------------------------------------------------------------------------
-- | The game monad transformer.  Embeds the necessary state in the game's
-- reactive loop without defaulting to the 'IO' monad.
--
-- The transformer is intended to stack with 'IO', in order to retrieve the
-- necessary information and display the results at each tick of the event
-- loop.  The inner loop itself can remain pure by using just 'GameM'.
newtype GameMT m a = GameMT { ungame :: StateT GameState m a }
    deriving (Functor, Applicative, Monad, MonadIO, MonadTrans)

instance Monad m => MonadRandom (GameMT m) where
    getRandom = runRandom random
    getRandomR r = runRandom $ randomR r

runRandom :: (Monad m, Random a) => (StdGen -> (a, StdGen)) -> GameMT m a
runRandom f = GameMT $ do
    s <- use stdGen
    let (a, s') = f s
    stdGen .= s'
    return a


------------------------------------------------------------------------------
-- | The pure form of the game monad.
type GameM = GameMT Identity


------------------------------------------------------------------------------
-- | The background state of the game.
data GameState = GameState
    { gsStdGen   :: StdGen
    , gsLastTime :: UTCTime
    }

lastTime :: Lens' GameState UTCTime
lastTime f gs = map (\t -> gs { gsLastTime = t }) $ f (gsLastTime gs)

stdGen :: Lens' GameState StdGen
stdGen f gs = map (\g -> gs { gsStdGen = g }) $ f (gsStdGen gs)


------------------------------------------------------------------------------
runGameMT :: MonadIO m => GameMT m a -> m a
runGameMT game = liftIO (liftM2 GameState getStdGen getCurrentTime) >>=
    evalStateT (ungame game)


------------------------------------------------------------------------------
-- | Lifts a pure game monad into the tranformer.  The resulting transformer
-- runs the given monad with its own state, then saves the resulting state.
liftGameM :: Monad m => GameM a -> GameMT m a
liftGameM game = GameMT $ do
    (a, s) <- runState (ungame game) `liftM` get
    put s
    return a


------------------------------------------------------------------------------
-- | Times the game ticks.  Running this action will save the current time,
-- and produce the time between the previous tick and this one.
tick :: MonadIO m => GameMT m Time
tick = GameMT $ do
    oldTime <- use lastTime
    newTime <- liftIO getCurrentTime
    lastTime .= newTime
    return . realToFrac $ newTime `diffUTCTime` oldTime

