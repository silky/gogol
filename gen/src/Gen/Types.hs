{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE ExtendedDefaultRules       #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE ViewPatterns               #-}

-- Module      : Gen.Types
-- Copyright   : (c) 2015 Brendan Hay
-- License     : Mozilla Public License, v. 2.0.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : provisional
-- Portability : non-portable (GHC extensions)

module Gen.Types
    ( module Gen.Types
    , module Gen.Types.Help
    , module Gen.Types.Id
    , module Gen.Types.Map
    , module Gen.Types.NS
    , module Gen.Types.Schema
    , module Gen.Types.Data
    ) where

import           Control.Lens               hiding ((.=))
import           Control.Monad.Except
import           Control.Monad.State.Strict
import           Data.Aeson                 hiding (Array, Bool, String)
import           Data.CaseInsensitive       (CI)
import qualified Data.CaseInsensitive       as CI
import           Data.Char
import           Data.Function              (on)
import qualified Data.HashMap.Strict        as Map
import qualified Data.HashSet               as Set
import           Data.List                  (sort)
import           Data.Ord
import           Data.Semigroup             ((<>))
import           Data.Text                  (Text)
import qualified Data.Text                  as Text
import qualified Data.Text.Lazy             as LText
import qualified Data.Text.Lazy.Builder     as Build
import           Data.Text.Manipulate
import           Debug.Trace
import qualified Filesystem.Path.CurrentOS  as Path
import           Formatting
import           Gen.Orphans                ()
import           Gen.Types.Data
import           Gen.Types.Help
import           Gen.Types.Id
import           Gen.Types.Map
import           Gen.Types.NS
import           Gen.Types.Schema
import           GHC.TypeLits
import           Prelude                    hiding (Enum)
import           Text.EDE                   (Template)

type Set   = Set.HashSet
type Error = LText.Text
type Path  = Path.FilePath

newtype Version (v :: Symbol) = Version Text
    deriving (Eq, Show)

instance ToJSON (Version v) where
    toJSON (Version v) = toJSON v

fver :: Format a (Version v -> a)
fver = later (\(Version v) -> Build.fromText v)

type LibraryVer = Version "library"
type ClientVer  = Version "client"
type CoreVer    = Version "core"

data Versions = Versions
    { _libraryVersion :: LibraryVer
    , _clientVersion  :: ClientVer
    , _coreVersion    :: CoreVer
    } deriving (Show)

makeClassy ''Versions

-- FIXME: need a more comprehensive 'vm_alpha' vs 'vm1.1' version check.
data Model = Model
    { modelName    :: Text
    , modelPrefix  :: Text
    , modelVersion :: Text
    , modelPath    :: Path
    }

instance Eq Model where
    (==) = on (==) modelPrefix

instance Ord Model where
    compare a b =
           on compare modelPrefix a b
        <> on compare (Down . modelVersion) a b

modelFromPath :: Path -> Model
modelFromPath x = Model n p v x
  where
    n = Text.init
      . Text.intercalate "/"
      . drop 1
      . dropWhile (/= "model")
      $ Text.split (== '/') p

    p = toTextIgnore (Path.parent (Path.parent x))
    v = toTextIgnore (Path.dirname x)

data Templates = Templates
    { cabalTemplate  :: Template
    , tocTemplate    :: Template
    , readmeTemplate :: Template
    , typesTemplate  :: Template
    , prodTemplate   :: Template
    , sumTemplate    :: Template
    , actionTemplate :: Template
    }

data Imports = Imports
    { tocImports    :: [NS]
    , typeImports   :: [NS]
    , prodImports   :: [NS]
    , sumImports    :: [NS]
    , actionImports :: [NS]
    }

serviceImports :: HasService a b => a -> Imports
serviceImports s = Imports
    { tocImports    = [preludeNS]
    , typeImports   = sort [preludeNS, prodNS s, sumNS s]
    , prodImports   = sort [preludeNS, sumNS s]
    , sumImports    = [preludeNS]
    , actionImports = sort [preludeNS, typesNS s]
    }

tocNS, typesNS, prodNS, sumNS :: HasService a b => a -> NS
tocNS   = mappend "Network.Google" . mkNS . view sCanonicalName
typesNS = (<> "Types")   . tocNS
prodNS  = (<> "Product") . typesNS
sumNS   = (<> "Sum")     . typesNS

preludeNS :: NS
preludeNS = "Network.Google.Prelude"

resourceNS, methodNS :: NS
resourceNS = "Network.Google.Resource"
methodNS   = "Network.Google.Method"

exposedModules :: Library -> [NS]
exposedModules l = sort $
      tocNS l
    : typesNS l
    : map _actNamespace (_apiResources (_lAPI l))
   ++ map _actNamespace (_apiMethods   (_lAPI l))

otherModules :: Library -> [NS]
otherModules s = sort [prodNS s, sumNS s]

toTextIgnore :: Path -> Text
toTextIgnore = either id id . Path.toText

data Library = Library
    { _lVersions :: Versions
    , _lService  :: Service Global
    , _lAPI      :: API
    , _lSchemas  :: [Data]
    }

makeLenses ''Library

instance HasVersions Library where
    versions = lVersions

instance HasDescription Library Global where
    description = lService . description

instance HasService Library Global where
    service = lService

instance ToJSON Library where
    toJSON l = object
        -- Library
        [ "libraryName"        .= (l ^. sLibrary)
        , "libraryTitle"       .= (l ^. dTitle)
        , "libraryDescription" .= Desc 4 (l ^. dDescription)
        , "libraryVersion"     .= (l ^. libraryVersion)
        , "coreVersion"        .= (l ^. coreVersion)
        , "clientVersion"      .= (l ^. clientVersion)
        , "exposedModules"     .= exposedModules l
        , "otherModules"       .= otherModules   l

        -- Service
       , "id"                  .= (l ^. dId)
       , "name"                .= (l ^. dName)
       , "version"             .= (l ^. dVersion)
       , "title"               .= (l ^. dTitle)
       , "description"         .= (l ^. dDescription)
       , "documentationLink"   .= (l ^. dDocumentationLink)
       , "labels"              .= (l ^. dLabels)
       , "features"            .= (l ^. dFeatures)

       -- API
       , "api"                 .= (l ^. lAPI)

       -- Schemas
       , "schemas"             .= (l ^. lSchemas)
       ]

data TType
    = TType  Global
    | TLit   Lit
    | TMaybe TType
    | TList  TType

data Derive
    = DEq
    | DOrd
    | DRead
    | DShow
    | DEnum
    | DNum
    | DIntegral
    | DReal
    | DMonoid
    | DIsString
    | DData
    | DTypeable
    | DGeneric
      deriving (Eq, Show)

data Solved = Solved
    { _unique   :: Global
    , _prefix   :: Prefix
    , _schema   :: Schema Global
    , _type     :: TType
    , _deriving :: [Derive]
    }

instance HasInfo Solved where
    info = f . info
      where
        f = lens _schema (\s a -> s { _schema = a })

monoid :: Solved -> Bool
monoid = elem DMonoid . _deriving

type Seen = Map (CI Text) {- Prefix -} (Set (CI Text)) {- Inhabitants -}

data Memo = Memo
    { _context  :: Service (Fix Schema)
    , _typed    :: Map Global TType
    , _derived  :: Map Global [Derive]
    , _schemas  :: Map Global (Schema Global)
    , _prefixed :: Map Global Prefix
    , _branches :: Seen
    , _fields   :: Seen
    }

initial :: Service (Fix Schema) -> Memo
initial s = Memo s mempty mempty core mempty mempty mempty
  where
    -- Types available in Network.Google.Prelude.
    core = Map.fromList
        [ ("Body", SLit requiredInfo Body)
        ]

makeLenses ''Memo

instance HasService Memo (Fix Schema) where
    service = context

type AST = ExceptT Error (State Memo)

reserveBranches :: AST ()
reserveBranches = do
    ss <- use schemas
    let bs = Set.fromList $ map (CI.mk . global) (Map.keys ss)
    branches %= Map.insertWith (<>) mempty bs

reserveFields :: AST ()
reserveFields = do
    ss <- use schemas
    forM_ (Map.keys ss) $ \(global -> k) -> do
        let p:ps = splitWords k
            s    = mconcat ps
        fields %= Map.insertWith (<>) (CI.mk p) (Set.singleton (CI.mk s))
