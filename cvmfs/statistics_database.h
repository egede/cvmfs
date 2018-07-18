/**
 * This file is part of the CernVM File System.
 */

#ifndef CVMFS_STATISTICS_DATABASE_H_
#define CVMFS_STATISTICS_DATABASE_H_

#include <ctime>
#include <string>

#include "options.h"
#include "sql.h"
#include "swissknife.h"
#include "util/posix.h"

typedef struct {
  std::string files_added;
  std::string files_removed;
  std::string files_changed;
  std::string dir_added;
  std::string dir_removed;
  std::string dir_changed;
  std::string bytes_added;
  std::string bytes_removed;
} Stats;

struct RevisionFlags {
  enum T {
    kInitialRevision   = 1,
    kUpdatableRevision = 2,
    kUpdatedRevision   = 3,
    kFailingRevision   = 4,
  };
};

class StatisticsDatabase : public sqlite::Database<StatisticsDatabase> {
 public:
  // not const - needs to be adaptable!
  static float        kLatestSchema;
  // not const - needs to be adaptable!
  static unsigned     kLatestSchemaRevision;
  static const float  kLatestCompatibleSchema;
  static bool         compacting_fails;
  static unsigned int  instances;
  unsigned int         create_empty_db_calls;
  unsigned int         check_compatibility_calls;
  unsigned int         live_upgrade_calls;
  mutable unsigned int compact_calls;

  bool CreateEmptyDatabase();
  bool CheckSchemaCompatibility();
  bool LiveSchemaUpgradeIfNecessary();
  bool CompactDatabase() const;
  ~StatisticsDatabase();

/**
  * Get command statistics values and convert them into strings.
  *
  * @param command to access counter statistics
  * @return a Stats struct with all statistics values stored in strings
  */
  Stats GetStats(swissknife::Command *command);

/**
  * Entry point function for writing data into database
  *
  * @return 0 if no error occured or a negative integer if errors occurred
  */
  int StoreStatistics(swissknife::Command *command);

/**
  * Get the path for the database file
  * user can specify it in the server.conf
  * by default: /var/spool/cvmfs/$repo_name/stats.db
  *
  * @param repo_name Fully qualified name of the repository
  * @return path to store database file
  */
  static std::string GetDBPath(std::string repo_name);

 protected:
  friend class sqlite::Database<StatisticsDatabase>;
  StatisticsDatabase(const std::string  &filename,
                const OpenMode      open_mode) :
    sqlite::Database<StatisticsDatabase>(filename, open_mode),
    create_empty_db_calls(0),  check_compatibility_calls(0),
    live_upgrade_calls(0), compact_calls(0)
  {
    ++StatisticsDatabase::instances;
  }

 private:
  /**
  * Get UTC Time.
  *
  * @return a timestamp in "YYYY-MM-DD HH:MM:SS" format
  */
  std::string GetGMTimestamp();

/**
  * Build the insert statement.
  *
  * @param stats a struct with all values stored in strings
  * @return the insert statement
  */
  std::string PrepareStatement(Stats stats);
};


#endif  // CVMFS_STATISTICS_DATABASE_H_
