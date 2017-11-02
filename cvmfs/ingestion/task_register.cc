/**
 * This file is part of the CernVM File System.
 */

#include "cvmfs_config.h"
#include "task_register.h"

#include <cassert>

#include "logging.h"

void TaskRegister::Process(FileItem *file_item) {
  assert(file_item != NULL);
  assert(!file_item->path().empty());
  assert(!file_item->has_legacy_bulk_chunk() ||
         !file_item->bulk_hash().IsNull());
  assert(file_item->nchunks_in_fly() == 0);
  assert((file_item->nchunks() > 1) || !file_item->bulk_hash().IsNull());
  assert(file_item->nchunks() != 1);
  assert(file_item->hash_suffix() == file_item->bulk_hash().suffix);

  LogCvmfs(kLogSpooler, kLogVerboseMsg,
           "File '%s' processed (bulk hash: %s suffix: %c)",
           file_item->path().c_str(),
           file_item->bulk_hash().ToString().c_str(),
           file_item->hash_suffix());

  FileChunkList pieces;
  NotifyListeners(upload::SpoolerResult(0,
    file_item->path(),
    file_item->bulk_hash(),
    pieces,
    file_item->compression_algorithm()));

  delete file_item;
  tube_counter_->Pop();
}
