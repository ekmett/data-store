{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
--------------------------------------------------------------------------------
-- |
--
-- Module    : Data.Store
-- Copyright : (c) Petr Pilar 2012
-- License   : BSD-style
--
-- Simple multi-key multi-value store with type-safe interface.
--
-- These modules are intended to be imported qualified to avoid name
-- clashes with prelude, e.g.:
--
-- > import qualified Data.Store as DS
-- > import           Data.Store.Key ((.:), (:.)(..))
-- > import           Data.Store.Query.Selection
--
-- Throughout out the documentation, the examples will be based on this
-- code:
--
-- > --------------------------------------------------------------------------------
-- > -- | TYPES
-- > 
-- > -- | Simple ADT representing an article.
-- > data Article = Article
-- >     { articleName :: TS.Text
-- >     , articleBody :: TS.Text
-- >     , articleTags :: [TS.Text]
-- >     } deriving (Eq, Ord, Show)
-- > 
-- > newtype ArticleID = ArticleID Int deriving (Eq, Ord, Show)
-- > 
-- > instance DS.Auto ArticleID where
-- >     initValue = ArticleID 1
-- >     nextValue (ArticleID n) = ArticleID $ n + 1
-- > 
-- > --------------------------------------------------------------------------------
-- > -- | BOILERPLATE 
-- > 
-- > -- | Type synonym for key key specification.
-- > type ArticleKeySpec =
-- >     (  (ArticleID, DS.DimAuto)
-- >     :. (TS.Text, DS.Dim)
-- >     :. (TS.Text, DS.Dim)
-- >     :. (TS.Text, DS.Dim) :. DS.K0)
-- > 
-- > data ArticleStoreTag 
-- > type ArticleStore    = DS.Store ArticleStoreTag ArticleKeySpec Article
-- > 
-- > type ArticleSelection = DS.Selection ArticleStoreTag ArticleKeySpec
-- > type ArticleKey = DS.Key ArticleKeySpec
-- > 
-- > articleKey :: Article -> ArticleKey
-- > articleKey (Article n b ts) = DS.dimA
-- >                            .: DS.dimN [n]
-- >                            .: DS.dimN [b]
-- >                            .: DS.K1 (DS.dimN ts)
-- > 
-- > -- | Shortcut for selecting on article ID.
-- > sArticleID :: Proxy (ArticleStoreTag, DS.N0)
-- > sArticleID = Proxy
-- > 
-- > -- | Shortcut for selecting on article name.
-- > sArticleName :: Proxy (ArticleStoreTag, DS.N1)
-- > sArticleName = Proxy
-- > 
-- > -- | Shortcut for selecting on article body.
-- > sArticleBody :: Proxy (ArticleStoreTag, DS.N2)
-- > sArticleBody = Proxy
-- > 
-- > -- | Shortcut for selecting on article tags.
-- > sArticleTag :: Proxy (ArticleStoreTag, DS.N3)
-- > sArticleTag = Proxy
-- > 
-- > -- | BOILERPLATE 
-- > --------------------------------------------------------------------------------
-- 
-- See the 'examples' directory for more complete examples.
module Data.Store
( I.Store

  -- * Store Operations
  -- ** Creation
, empty
, fromList

  -- ** Insertion
, insert
, insert'

  -- ** Updates
, update

  -- ** Query
, lookup
, lookup'
, size

, debugShow
) where

--------------------------------------------------------------------------------
import           Prelude hiding (lookup)
--------------------------------------------------------------------------------
import           Control.Arrow
import           Control.Applicative hiding (empty)
--------------------------------------------------------------------------------
import qualified Data.IntMap       as IM
import qualified Data.IntSet       as IS
import qualified Data.Map          as M
import qualified Data.Vector       as V
import qualified Data.Vector.Extra as V
import qualified Data.List         as L
import           Data.Proxy
--------------------------------------------------------------------------------
import qualified Data.Store.Key                     as I
import qualified Data.Store.Query                   as I
import qualified Data.Store.Internal                as I
import qualified Data.Store.Internal.Key            as I
import qualified Data.Store.Internal.Index          as I
--------------------------------------------------------------------------------

-- | The name of this module.
moduleName :: String
moduleName = "Data.Store"

-- | Given a key specification, this type family gives you the type
-- of result of inserting into a 'Data.Store.Store' with that key
-- specification.
--
-- Examples:
--
-- > InsertResult ((String, Dim) :. (Int, DimAuto) :. K0) ~ (Int :. ())
-- > InsertResult ((Int, DimAuto) :. (Int, DimAuto) :. K0) ~ (Int :. Int :. ())
type family   InsertResult a :: *
type instance InsertResult ((a, I.Dim)     I.:. I.K0) = ()
type instance InsertResult ((a, I.DimAuto) I.:. I.K0) = a I.:. ()
type instance InsertResult ((a, I.Dim)     I.:. (b, dt) I.:. r) = InsertResult ((I.:.) (b, dt) r)
type instance InsertResult ((a, I.DimAuto) I.:. (b, dt) I.:. r) = (I.:.) a (InsertResult ((I.:.) (b, dt) r))

-- | Creates an empty 'Store'.
--
-- TODO: Find a way to remove the 'CEmptyKey' context. Find a way to get
-- rid of the scoped type varaibles.
empty :: forall tag spec v . (I.CEmptyKey (I.Key spec))
      => I.Store tag spec v
empty = I.Store
    { I.storeValues = IM.empty
    , I.storeIndex  = emptyStoreIndex ekey
    , I.storeNextID = 1
    }
    where
      ekey :: I.Key spec 
      ekey = I.emptyKey

      emptyStoreIndex :: forall spec1 . I.Key spec1 -> I.StoreIndex
      emptyStoreIndex (I.K1 d)   = V.singleton $ emptyIndex d
      emptyStoreIndex (I.KN d r) = emptyIndex d `V.cons` emptyStoreIndex r 

      emptyIndex :: forall a d . I.Dimension a d -> I.Index
      emptyIndex (I.Dimension _) = I.Index     (M.empty :: M.Map a IS.IntSet)
      emptyIndex I.DimensionAuto = I.IndexAuto (M.empty :: M.Map a IS.IntSet) I.initValue

-- | Creates a 'Store' that contains the given key-value pairs.
--
-- TODO: Examples, Complexity.
fromList :: I.CEmptyKey (I.Key spec) => [(I.Key spec, v)] -> I.Store tag spec v
fromList = L.foldl' (\acc (k, v) -> insert' k v acc) empty
{-# INLINEABLE fromList #-}

-- | The expression @('lookup' sel store)@ gives you a list of the elements
-- in the given selection.
--
-- Examples:
--
-- >>> -- Fetch articles with title "Haskell" or that are tagged with the "Haskell" tag.
-- >>> lookup (sArticleTitle .== "Haskell" .|| sArticleTag .== "Haskell") store
-- [(Article <something>, ArticleID 1 :. ())]
--
-- TODO: Complexity.
lookup :: I.Selection tag k
       -> I.Store tag k v
       -> [(v, InsertResult k)]
lookup selection = I.runQuery (go <$> resolve selection <*> I.queryStore)
    where
      go :: IS.IntSet -> I.Store tag k v -> [(v, InsertResult k)]
      go oids (I.Store values _ _) =
          IS.foldl' (\acc oid -> maybe acc (\(v, k) -> (v, insertResult k) : acc)
                                           (IM.lookup oid values)
                    ) [] oids

      insertResult :: I.KeyInternal k -> InsertResult k
      insertResult (I.K1 (I.IDimension _)) = ()
      insertResult (I.K1 (I.IDimensionAuto x)) = x I.:. ()
      insertResult (I.KN (I.IDimension _) r) = insertResult r
      insertResult (I.KN (I.IDimensionAuto x) r) = x I.:. insertResult r

-- | The expression @('lookup'' sel store)@ gives you a list of the elements
-- in the given selection. It does not include the 'InsertResult' as
-- 'lookup' does.
--
-- Semantically equivalent to @(map fst $ 'lookup' sel store)@.
--
-- Examples:
--
-- >>> -- Fetch articles with title "Haskell" or that are tagged with the "Haskell" tag.
-- >>> lookup (sArticleTitle .== "Haskell" .|| sArticleTag .== "Haskell") store
-- [(Article <something>)]
--
-- TODO: Complexity.
lookup' :: I.Selection tag k
        -> I.Store tag k v
        -> [v]
lookup' selection = I.runQuery (go <$> resolve selection <*> I.queryStore)
    where
      go :: IS.IntSet -> I.Store tag k v -> [v]
      go oids (I.Store values _ _) =
          IS.foldl' (\acc oid -> maybe acc (\(v, _) -> v : acc)
                                           (IM.lookup oid values)
                    ) [] oids

-- | The expression @('size' store)@ gives you the number of elements currently
-- in the store.
--
-- Examples:
--
-- >>> size empty
-- 0
-- >>> size $ insert key value empty
-- > 1
--
-- Complexity: /O(n)/
size :: I.Store tag k v -> Int
size (I.Store values _ _) = IM.size values
{-# INLINEABLE size #-}

-- | The expression @('insert' k v store)@ inserts the given
-- value @v@ under the key @k@. 
--
-- >>> let article = Article "About Haskell" "Haskell is great!" ["Haskell"]
-- >>> insert (articleKey article) article store
-- (<updated_store>, ArticleID 1 :. ())
-- 
-- TODO: Complexity.
insert :: I.Key spec                  
       -> v                           
       -> I.Store tag spec v
       -> (I.Store tag spec v, InsertResult spec)
insert key value I.Store{..} = (I.Store
    { I.storeValues = IM.insert storeNextID (value, keyInternal) storeValues
    , I.storeIndex  = newStoreIndex 
    , I.storeNextID = succ storeNextID 
    }, toInsertResult keyInternal)
    where
      (newStoreIndex, keyInternal) = insertToIndex 0 key storeIndex

      -- | Recursively inserts the new ID under indices of every dimension
      -- of the key.
      insertToIndex :: Int            -- ^ The position of the dimension of the head of the key in the store index vector.
                    -> I.Key spec     -- ^ The key.
                    -> I.StoreIndex   -- ^ The store index.
                    -> (I.StoreIndex, I.KeyInternal spec)
      -- Standard dimension, 1-dimensional key.
      insertToIndex d (I.K1 kh@(I.Dimension _)) index =
          second I.K1 $ indexUpdate kh d index

      -- Auto-increment dimension, 1-dimensional key.
      insertToIndex d (I.K1 kh@I.DimensionAuto) index =
          second I.K1 $ indexUpdate kh d index

      -- Standard dimension, (n + 1)-dimensional key.
      insertToIndex d (I.KN kh@(I.Dimension _) kt) index =
          let (nindex, res) = indexUpdate kh d index
          in  second (I.KN res) $ insertToIndex (d + 1) kt nindex    

      -- Auto-increment dimension (n + 1)-dimensional key.
      insertToIndex d (I.KN kh@I.DimensionAuto kt) index =
          let (nindex, res) = indexUpdate kh d index
          in  second (I.KN res) $ insertToIndex (d + 1) kt nindex    

      -- | Inserts the new ID under indices of the given dimension.
      indexUpdate :: I.Dimension a d -- ^ The dimension to be inserted.
                  -> Int             -- ^ The position of the dimension in the store index vector.
                  -> I.StoreIndex    -- ^ The store index.
                  -> (I.StoreIndex, I.DimensionInternal a d)
      indexUpdate d = V.updateAt' (I.insertDimension d storeNextID)

      toInsertResult :: I.KeyInternal spec
                     -> InsertResult spec
      toInsertResult (I.K1 (I.IDimensionAuto v))    = v I.:. ()
      toInsertResult (I.K1 (I.IDimension _))        = ()
      toInsertResult (I.KN (I.IDimensionAuto v) kt) = v I.:. toInsertResult kt
      toInsertResult (I.KN (I.IDimension _) kt)     = toInsertResult kt

-- | The expression @('insert'' k v store)@ inserts the given
-- value @v@ under the key @k@. Unlike 'insert', tt does not return the assigned values of
-- automatic dimension of the key.
--
-- Semantically equivalent to @(fst $ 'insert' k v store)@.
--
-- >>> let article = Article "About Haskell" "Haskell is great!" ["Haskell"]
-- >>> insert (articleKey article) article store
-- <updated_store>
-- 
-- TODO: Complexity.
insert' :: I.Key spec                  
        -> v                           
        -> I.Store tag spec v
        -> I.Store tag spec v
insert' k v = fst . insert k v

-- | The expression @('update' f sel store)@ updates all values @x@ that are
-- part of the selection @sel@. If @(f x)@ is 'Nothing', the element is
-- deleted. If it is @('Just' (y, 'Nothing'))@, it's changed under its current
-- key. If it is @('Just' (y, 'Just' k))@ it's changed together with its key.
--
-- Examples:
--
-- >>> -- Deletes the elements that fit the selection criteria.
-- >>> update (const Nothing) (sArticleTag .== "Python") store
-- <updated_store>
--
-- >>> -- Changes the elements that fit the selection, but keeps their old keys.
-- >>> let article = Article "Untitled" "No Content." []
-- >>> update (const $ Just (article, Nothing)) everything store
-- <updated_store>
--
-- >>> -- Changes the elements and associated keys that fit the selection criteria
-- >>> let article = Article "Untitled" "No Content." []
-- >>> update (const $ Just (article, Just $ articleKey article)) everything store
-- <updated_store>
--
-- TODO: Complexity.
update :: (v -> Maybe (v, Maybe (I.Key k)))
       -> I.Selection tag k
       -> I.Store tag k v 
       -> I.Store tag k v 
update fun querySelection = I.runQuery (go <$> resolve querySelection <*> I.queryStore)
    where
      -- go :: IS.IntSet -> I.Store tag k v -> I.Store tag k v
      go selection store = IS.foldl' step store selection

      -- step :: I.Store tag k v -> Int -> I.Store tag k v
      step acc@(I.Store values index _) oid =
          case IM.lookup oid values of
              -- Object with the given ID does not exist.
              Nothing -> acc
              Just (v, k) ->
                case fun v of
                    -- We are changing the value of the object.
                    Just (nv, Nothing) -> acc
                      { I.storeValues = IM.insert oid (nv, k) values
                      }
                    -- We are changing the value and key of the object.
                    Just (nv, Just nk) -> acc
                      { I.storeValues = IM.insert oid (nv, newKey) values
                      , I.storeIndex  = insertByKey newKey oid $ deleteByKey k oid index -- TODO: Look into efficiency here.
                      }
                      where
                        newKey = makeKey k nk
                    -- We are deleting the object. 
                    Nothing -> acc
                      { I.storeValues = IM.delete oid values
                      , I.storeIndex  = deleteByKey k oid index -- TODO: Look into efficiency here.
                      }

      -- | Gven a 'KeyInternal' and a 'Key', it merges them into a new
      -- 'KeyInternal'. The values of auto-increment dimensions are from
      -- the original 'KeyInternal'.
      makeKey :: I.KeyInternal kx -> I.Key kx -> I.KeyInternal kx
      makeKey (I.K1 (I.IDimension _)) (I.K1 (I.Dimension xs)) = I.K1 (I.IDimension xs)
      makeKey (I.K1 (I.IDimensionAuto k)) (I.K1 I.DimensionAuto) = I.K1 (I.IDimensionAuto k)
      makeKey (I.KN (I.IDimension _) r) (I.KN (I.Dimension xs) nr) = I.KN (I.IDimension xs) (makeKey r nr)
      makeKey (I.KN (I.IDimensionAuto k) r) (I.KN I.DimensionAuto nr) = I.KN (I.IDimensionAuto k) (makeKey r nr)
      makeKey _ _ = error $ moduleName ++ ".update: impossible happened." -- This can not happen.

      -- | Deletes the given object ID from the index under the given key.
      deleteByKey :: I.KeyInternal spec -> I.ObjectID -> I.StoreIndex -> I.StoreIndex 
      deleteByKey ikey oid sindex = go' ikey sindex 0
        where
          go' :: I.KeyInternal spec -> I.StoreIndex -> Int -> I.StoreIndex
          go' (I.K1 (I.IDimension ks))    acc n = V.updateAt (I.delete ks oid)  n acc
          go' (I.K1 (I.IDimensionAuto k)) acc n = V.updateAt (I.delete [k] oid) n acc
          go' (I.KN (I.IDimension ks) r)    acc n = V.updateAt (I.delete ks oid)  n $ go' r acc (n + 1) 
          go' (I.KN (I.IDimensionAuto k) r) acc n = V.updateAt (I.delete [k] oid) n $ go' r acc (n + 1) 
     
      -- | Inserts the given object ID into the index under the given key.
      insertByKey :: I.KeyInternal spec -> I.ObjectID -> I.StoreIndex -> I.StoreIndex 
      insertByKey ikey oid sindex = go' ikey sindex 0
        where
          go' :: I.KeyInternal spec -> I.StoreIndex -> Int -> I.StoreIndex
          go' (I.K1 d)   acc n = V.updateAt (I.insertDimensionInternal d oid) n acc
          go' (I.KN d r) acc n = V.updateAt (I.insertDimensionInternal d oid) n $ go' r acc (n + 1) 

resolve :: I.Selection tag k -> I.Query tag k v IS.IntSet
resolve selection = go selection <$> I.queryStore
    where
      go :: I.Selection tag k -> I.Store tag k v -> IS.IntSet
      go (I.SelectGT p x) (I.Store _ index _) = snd $ I.split x $ index V.! I.toInt (sndProxy p)
      go (I.SelectLT p x) (I.Store _ index _) = fst $ I.split x $ index V.! I.toInt (sndProxy p)
      go (I.SelectEQ p x) (I.Store _ index _) = I.lookup x $ index V.! I.toInt (sndProxy p) 
      go (I.SelectGTE p x) (I.Store _ index _) =
          let (_, e, g) = I.splitLookup x $ index V.! I.toInt (sndProxy p)
          in  IS.union e g
      go (I.SelectLTE p x) (I.Store _ index _) =  
          let (l, e, _) = I.splitLookup x $ index V.! I.toInt (sndProxy p)
          in  IS.union l e

      -- Union
      go (I.SelectOR I.SelectALL _) st = go I.SelectALL st
      go (I.SelectOR _ I.SelectALL) st = go I.SelectALL st
      go (I.SelectOR I.SelectNONE s) st = go s st
      go (I.SelectOR s I.SelectNONE) st = go s st
      go (I.SelectOR  s1 s2) st = go s1 st `IS.union` go s2 st

      -- Intersection
      go (I.SelectAND I.SelectNONE _) st = go I.SelectNONE st
      go (I.SelectAND _ I.SelectNONE) st = go I.SelectNONE st
      go (I.SelectAND I.SelectALL s) st = go s st
      go (I.SelectAND s I.SelectALL) st = go s st
      go (I.SelectAND s1 s2) st = go s1 st `IS.intersection` go s2 st

      go I.SelectNONE _ = IS.empty
      go I.SelectALL (I.Store values _ _) =
          IM.foldlWithKey' (\acc oid _ -> IS.insert oid $! acc) IS.empty values

      sndProxy :: Proxy (a, b) -> Proxy b
      sndProxy = reproxy
      {-# INLINEABLE sndProxy #-}

debugShow :: (Show a1, Show a2, Show a3, Show a4, Show v) => I.Store tag ((a1, dt1) I.:. (a2, dt2) I.:. (a3, dt3) I.:. (a4, dt4) I.:. I.K0) v -> String
debugShow (I.Store values index noid) = unlines
    [ "Store values: " ++ show values
    , "Store index: " ++ show index
    , "Store next oid: " ++ show noid
    ]

