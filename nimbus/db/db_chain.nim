# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  tables, sequtils, algorithm,
  rlp, ranges, state_db, nimcrypto, eth_trie/[hexary, db], eth_common, byteutils,
  ../errors, ../block_types, ../utils/header, ../constants, ./storage_types.nim

type
  BaseChainDB* = ref object
    db*:           TrieDatabaseRef
    # XXX: intentionally simple stand-in for one use of full JournalDB
    # Doesn't handle CREATE+revert, etc. But also creates minimal tech
    # debt while setting a CI baseline from which to improve/replace.
    accountCodes*: TableRef[Hash256, ByteRange]
    # TODO db*: JournalDB

  KeyType = enum
    blockNumberToHash
    blockHashToScore

  TransactionKey = tuple
    blockNumber: BlockNumber
    index: int

proc newBaseChainDB*(db: TrieDatabaseRef): BaseChainDB =
  new(result)
  result.db = db
  result.accountCodes = newTable[Hash256, ByteRange]()

proc `$`*(db: BaseChainDB): string =
  result = "BaseChainDB"

proc getBlockHeader*(self: BaseChainDB; blockHash: Hash256, output: var BlockHeader): bool =
  let data = self.db.get(genericHashKey(blockHash).toOpenArray).toRange
  if data.len != 0:
    output = rlp.decode(data, BlockHeader)
    result = true

proc getBlockHeader*(self: BaseChainDB, blockHash: Hash256): BlockHeader =
  ## Returns the requested block header as specified by block hash.
  ##
  ## Raises BlockNotFound if it is not present in the db.
  if not self.getBlockHeader(blockHash, result):
    raise newException(BlockNotFound, "No block with hash " & blockHash.data.toHex)

proc getHash(self: BaseChainDB, key: DbKey, output: var Hash256): bool {.inline.} =
  let data = self.db.get(key.toOpenArray).toRange
  if data.len != 0:
    output = rlp.decode(data, Hash256)
    result = true

proc getCanonicalHead*(self: BaseChainDB): BlockHeader =
  var headHash: Hash256
  if not self.getHash(canonicalHeadHashKey(), headHash) or
      not self.getBlockHeader(headHash, result):
    raise newException(CanonicalHeadNotFound,
                      "No canonical head set for this chain")

proc getBlockHash*(self: BaseChainDB, n: BlockNumber, output: var Hash256): bool {.inline.} =
  ## Return the block hash for the given block number.
  self.getHash(blockNumberToHashKey(n), output)

proc getBlockHash*(self: BaseChainDB, n: BlockNumber): Hash256 {.inline.} =
  ## Return the block hash for the given block number.
  if not self.getHash(blockNumberToHashKey(n), result):
    raise newException(BlockNotFound, "No block hash for number " & $n)

proc getBlockHeader*(self: BaseChainDB; n: BlockNumber, output: var BlockHeader): bool =
  ## Returns the block header with the given number in the canonical chain.
  var blockHash: Hash256
  if self.getBlockHash(n, blockHash):
    result = self.getBlockHeader(blockHash, output)

proc getBlockHeader*(self: BaseChainDB; n: BlockNumber): BlockHeader =
  ## Returns the block header with the given number in the canonical chain.
  ## Raises BlockNotFound error if the block is not in the DB.
  self.getBlockHeader(self.getBlockHash(n))

proc getBlockBody*(self: BaseChainDB, h: Hash256, output: var BlockBody): bool =
  discard # TODO:

proc getScore*(self: BaseChainDB; blockHash: Hash256): int =
  rlp.decode(self.db.get(blockHashToScoreKey(blockHash).toOpenArray).toRange, int)

iterator findNewAncestors(self: BaseChainDB; header: BlockHeader): BlockHeader =
  ##         Returns the chain leading up from the given header until the first ancestor it has in
  ##         common with our canonical chain.
  var h = header
  var orig: BlockHeader
  while true:
    if self.getBlockHeader(h.blockNumber, orig) and orig.hash == h.hash:
      break

    yield h

    if h.parentHash == GENESIS_PARENT_HASH:
      break
    else:
      h = self.getBlockHeader(h.parentHash)

proc addBlockNumberToHashLookup(self: BaseChainDB; header: BlockHeader) =
  self.db.put(blockNumberToHashKey(header.blockNumber).toOpenArray,
              rlp.encode(header.hash))

iterator getBlockTransactionHashes(self: BaseChainDB, blockHeader: BlockHeader): Hash256 =
  ## Returns an iterable of the transaction hashes from th block specified
  ## by the given block header.
  doAssert(false, "TODO: Implement me")
  # let all_encoded_transactions = self._get_block_transaction_data(
  #   blockHeader.transactionRoot,
  # )
  # for encoded_transaction in all_encoded_transactions:
  #     yield keccak(encoded_transaction)

proc getTransactionKey*(self: BaseChainDB, transactionHash: Hash256): tuple[blockNumber: BlockNumber, index: int] {.inline.} =
  let
    tx = self.db.get(transactionHashToBlockKey(transactionHash).toOpenArray).toRange
    key = rlp.decode(tx, TransactionKey)
  return (key.blockNumber, key.index)

proc removeTransactionFromCanonicalChain(self: BaseChainDB, transactionHash: Hash256) {.inline.} =
  ## Removes the transaction specified by the given hash from the canonical chain.
  self.db.del(transactionHashToBlockKey(transactionHash).toOpenArray)

proc setAsCanonicalChainHead(self: BaseChainDB; headerHash: Hash256): seq[BlockHeader] =
  ##         Sets the header as the canonical chain HEAD.
  let header = self.getBlockHeader(headerHash)

  var newCanonicalHeaders = sequtils.toSeq(findNewAncestors(self, header))
  reverse(newCanonicalHeaders)
  for h in newCanonicalHeaders:
    var oldHash: Hash256
    if not self.getBlockHash(h.blockNumber, oldHash):
      break

    let oldHeader = self.getBlockHeader(oldHash)
    for txHash in self.getBlockTransactionHashes(oldHeader):
      self.removeTransactionFromCanonicalChain(txHash)
      # TODO re-add txn to internal pending pool (only if local sender)

  for h in newCanonicalHeaders:
    self.addBlockNumberToHashLookup(h)

  self.db.put(canonicalHeadHashKey().toOpenArray, rlp.encode(headerHash))

  return newCanonicalHeaders

proc headerExists*(self: BaseChainDB; blockHash: Hash256): bool =
  ## Returns True if the header with the given block hash is in our DB.
  self.db.contains(genericHashKey(blockHash).toOpenArray)

iterator getBlockTransactionData(self: BaseChainDB, transactionRoot: Hash256): BytesRange =
  var transactionDb = initHexaryTrie(self.db, transactionRoot)
  var transactionIdx = 0
  while true:
    let transactionKey = rlp.encode(transactionIdx).toRange
    if transactionKey in transactionDb:
      yield transactionDb.get(transactionKey)
    else:
      break
    inc transactionIdx

iterator getReceipts*(self: BaseChainDB; header: BlockHeader; receiptClass: typedesc): Receipt =
  var receiptDb = initHexaryTrie(self.db, header.receiptRoot)
  var receiptIdx = 0
  while true:
    let receiptKey = rlp.encode(receiptIdx).toRange
    if receiptKey in receiptDb:
      let receiptData = receiptDb.get(receiptKey)
      yield rlp.decode(receiptData, receiptClass)
    else:
      break
    inc receiptIdx

iterator getBlockTransactions(self: BaseChainDB; transactionRoot: Hash256;
                              transactionClass: typedesc): transactionClass =
  for encodedTransaction in self.getBlockTransactionData(transactionRoot):
    yield rlp.decode(encodedTransaction, transactionClass)

proc persistHeaderToDb*(self: BaseChainDB; header: BlockHeader): seq[BlockHeader] =
  let isGenesis = header.parentHash == GENESIS_PARENT_HASH
  let headerHash = header.blockHash
  if not isGenesis and not self.headerExists(header.parentHash):
    raise newException(ParentNotFound, "Cannot persist block header " &
        $headerHash & " with unknown parent " & $header.parentHash)
  self.db.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header))

  let score = if isGenesis: header.difficulty
              else: self.getScore(header.parentHash).u256 + header.difficulty
  self.db.put(blockHashToScoreKey(headerHash).toOpenArray, rlp.encode(score))

  self.addBlockNumberToHashLookup(header)

  var headScore: int
  try:
    headScore = self.getScore(self.getCanonicalHead().hash)
  except CanonicalHeadNotFound:
    return self.setAsCanonicalChainHead(headerHash)

  if score > headScore.u256:
    result = self.setAsCanonicalChainHead(headerHash)

proc addTransactionToCanonicalChain(self: BaseChainDB, txHash: Hash256,
    blockHeader: BlockHeader, index: int) =
  let k: TransactionKey = (blockHeader.blockNumber, index)
  self.db.put(transactionHashToBlockKey(txHash).toOpenArray, rlp.encode(k))

proc persistUncles*(self: BaseChainDB, uncles: openarray[BlockHeader]): Hash256 =
  ## Persists the list of uncles to the database.
  ## Returns the uncles hash.
  let enc = rlp.encode(uncles)
  result = keccak256.digest(enc)
  self.db.put(genericHashKey(result).toOpenArray, enc)

proc persistBlockToDb*(self: BaseChainDB; blk: Block) =
  ## Persist the given block's header and uncles.
  ## Assumes all block transactions have been persisted already.
  let newCanonicalHeaders = self.persistHeaderToDb(blk.header)
  for header in newCanonicalHeaders:
    var index = 0
    for txHash in self.getBlockTransactionHashes(header):
      self.addTransactionToCanonicalChain(txHash, header, index)
      inc index

  if blk.uncles.len != 0:
    let ommersHash = self.persistUncles(blk.uncles)
    assert ommersHash == blk.header.ommersHash

# proc addTransaction*(self: BaseChainDB; blockHeader: BlockHeader; indexKey: cstring;
#                     transaction: FrontierTransaction): cstring =
#   var transactionDb = HexaryTrie(self.db)
#   transactionDb[indexKey] = rlp.encode(transaction)
#   return transactionDb.rootHash

# proc addReceipt*(self: BaseChainDB; blockHeader: BlockHeader; indexKey: cstring;
#                 receipt: Receipt): cstring =
#   var receiptDb = HexaryTrie()
#   receiptDb[indexKey] = rlp.encode(receipt)
#   return receiptDb.rootHash

#proc snapshot*(self: BaseChainDB): UUID =
  # Snapshots are a combination of the state_root at the time of the
  # snapshot and the id of the changeset from the journaled DB.  
  #return self.db.snapshot()

# proc commit*(self: BaseChainDB; checkpoint: UUID): void =
#   self.db.commit(checkpoint)

# proc clear*(self: BaseChainDB): void =
#   self.db.clear()

proc getStateDb*(self: BaseChainDB; stateRoot: Hash256; readOnly: bool = false): AccountStateDB =
  # TODO: readOnly is not used.
  result = newAccountStateDB(self.db, stateRoot, readOnly, self.accountCodes)


# Deprecated:
proc getBlockHeaderByHash*(self: BaseChainDB; blockHash: Hash256): BlockHeader {.deprecated.} =
  self.getBlockHeader(blockHash)

proc lookupBlockHash*(self: BaseChainDB; n: BlockNumber): Hash256 {.deprecated.} =
  self.getBlockHash(n)

proc getCanonicalBlockHeaderByNumber*(self: BaseChainDB; n: BlockNumber): BlockHeader {.deprecated.} =
  self.getBlockHeader(n)

