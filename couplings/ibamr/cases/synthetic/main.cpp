#include "CouplingDriver.h"
#include "CpuLearnerEnvironment.h"

#include <smarties.h>

#include <mpi.h>

#include <dirent.h>

#include <cmath>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace
{
using Environment = ibamr_smarties::synthetic::CpuLearnerEnvironment;

struct ProtocolReport
{
  unsigned episodes = 0;
  unsigned decisions = 0;
  bool finite = true;
};

ProtocolReport protocol_report;

std::vector<double> asVector(const Environment::State& state)
{
  return std::vector<double>(state.begin(), state.end());
}

bool hasFlag(const int argc, char** const argv, const std::string& name)
{
  for(int i=1; i<argc; ++i)
    if(argv[i] != nullptr && name == argv[i]) return true;
  return false;
}

std::string optionValue(const int argc,
                        char** const argv,
                        const std::string& name,
                        const std::string& fallback)
{
  const std::string prefix = name + "=";
  for(int i=1; i<argc; ++i)
  {
    const std::string argument = argv[i] == nullptr ? "" : argv[i];
    if(argument == name && i+1 < argc && argv[i+1] != nullptr)
      return argv[i+1];
    if(argument.compare(0, prefix.size(), prefix) == 0)
      return argument.substr(prefix.size());
  }
  return fallback;
}

std::uint64_t parseSeed(const int argc, char** const argv)
{
  const std::string value = optionValue(argc, argv, "--randSeed", "0");
  std::size_t parsed = 0;
  const unsigned long long seed = std::stoull(value, &parsed);
  if(parsed != value.size() || seed == 0)
    throw std::invalid_argument("--randSeed must be a positive integer");
  return static_cast<std::uint64_t>(seed);
}

std::uint64_t environmentIdentity(const MPI_Comm environment_comm)
{
  int environment_rank = 0;
  MPI_Comm_rank(environment_comm, &environment_rank);

  MPI_Group environment_group = MPI_GROUP_NULL;
  MPI_Group world_group = MPI_GROUP_NULL;
  MPI_Comm_group(environment_comm, &environment_group);
  MPI_Comm_group(MPI_COMM_WORLD, &world_group);
  const int local_root = 0;
  int world_root = MPI_UNDEFINED;
  MPI_Group_translate_ranks(environment_group, 1, &local_root,
                            world_group, &world_root);
  MPI_Group_free(&environment_group);
  MPI_Group_free(&world_group);
  if(world_root == MPI_UNDEFINED)
    throw std::runtime_error("cannot derive synthetic environment identity");
  return static_cast<std::uint64_t>(world_root);
}

void printSummary(const std::uint64_t seed,
                  const std::uint64_t environment_id,
                  const double total_return,
                  const double total_squared_error)
{
  const double mean_return = protocol_report.episodes == 0 ? 0.0 :
    total_return / static_cast<double>(protocol_report.episodes);
  const double action_mse = protocol_report.decisions == 0 ? 0.0 :
    total_squared_error / static_cast<double>(protocol_report.decisions);
  std::printf("SMARTIES_SYNTHETIC_SUMMARY seed=%llu environment=%llu "
              "episodes=%u decisions=%u mean_return=%.17g action_mse=%.17g "
              "finite=%d\n",
              static_cast<unsigned long long>(seed),
              static_cast<unsigned long long>(environment_id),
              protocol_report.episodes, protocol_report.decisions,
              mean_return, action_mse, protocol_report.finite ? 1 : 0);
  std::fflush(stdout);
}

void runSyntheticEnvironment(smarties::Communicator* const comm,
                             const MPI_Comm environment_comm,
                             const std::uint64_t seed,
                             const bool protocol_pacing)
{
  int environment_rank = 0;
  int environment_size = 0;
  MPI_Comm_rank(environment_comm, &environment_rank);
  MPI_Comm_size(environment_comm, &environment_size);

  try
  {
    if(environment_size != 1)
      throw std::runtime_error("synthetic environment requires one MPI rank");
    const std::uint64_t environment_id =
      environmentIdentity(environment_comm);
    Environment environment(seed, environment_id);
    protocol_report = ProtocolReport();
    double total_return = 0.0;
    double total_squared_error = 0.0;

    comm->setStateActionDims(Environment::state_dimension, 1);
    comm->setActionScales({ 1.0 }, { -1.0 }, true);
    if(!comm->isTraining()) comm->disableDataTrackingForAgents(0, 1);

    while(!comm->terminateTraining())
    {
      environment.reset();
      comm->sendInitState(asVector(environment.state()));
      double episode_return = 0.0;
      double episode_squared_error = 0.0;

      for(unsigned step=0; step<Environment::episode_length; ++step)
      {
        const std::vector<double> action = comm->recvAction();
        if(comm->terminateTraining())
        {
          printSummary(seed, environment_id, total_return,
                       total_squared_error);
          return;
        }
        if(action.size() != 1)
          throw std::runtime_error("synthetic action must have dimension one");

        const auto transition = environment.advance(action.at(0));
        const double squared_error = -transition.reward;
        const bool finite = std::isfinite(action.at(0)) &&
          std::isfinite(transition.target_action) &&
          std::isfinite(transition.reward);
        protocol_report.finite = protocol_report.finite && finite;
        ++protocol_report.decisions;
        episode_return += transition.reward;
        episode_squared_error += squared_error;
        total_return += transition.reward;
        total_squared_error += squared_error;

        std::printf("SMARTIES_SYNTHETIC_STEP seed=%llu environment=%llu "
                    "episode=%llu decision=%u action=%.17g target=%.17g "
                    "reward=%.17g squared_error=%.17g terminal=%d finite=%d\n",
                    static_cast<unsigned long long>(seed),
                    static_cast<unsigned long long>(environment_id),
                    static_cast<unsigned long long>(transition.episode),
                    transition.decision, action.at(0),
                    transition.target_action, transition.reward,
                    squared_error, transition.terminal ? 1 : 0,
                    finite ? 1 : 0);

        if(transition.terminal)
        {
          comm->sendTermState(asVector(transition.state), transition.reward);
          ++protocol_report.episodes;
          std::printf("SMARTIES_SYNTHETIC_EPISODE seed=%llu environment=%llu "
                      "episode=%llu decisions=%u return=%.17g mse=%.17g "
                      "finite=%d\n",
                      static_cast<unsigned long long>(seed),
                      static_cast<unsigned long long>(environment_id),
                      static_cast<unsigned long long>(transition.episode),
                      transition.decision, episode_return,
                      episode_squared_error /
                        static_cast<double>(transition.decision),
                      protocol_report.finite ? 1 : 0);
        }
        else
          comm->sendState(asVector(transition.state), transition.reward);
        if(protocol_pacing)
          std::this_thread::sleep_for(std::chrono::milliseconds(20));
      }
      std::fflush(stdout);
    }
    printSummary(seed, environment_id, total_return, total_squared_error);
  }
  catch(const std::exception& error)
  {
    if(environment_rank == 0)
      std::fprintf(stderr, "synthetic environment fatal error: %s\n",
                   error.what());
    MPI_Abort(environment_comm, 66);
  }
}

long countAuditStage(const std::string& path, const std::string& stage)
{
  std::ifstream input(path);
  long count = 0;
  std::string line;
  const std::string token = " stage=" + stage + " ";
  while(std::getline(input, line))
    if(line.find(token) != std::string::npos) ++count;
  return count;
}

unsigned directoryEntryCount(const std::string& path)
{
  DIR* const directory = opendir(path.c_str());
  if(directory == nullptr) return 0;
  unsigned count = 0;
  while(const dirent* const entry = readdir(directory))
  {
    const std::string name = entry->d_name;
    if(name != "." && name != "..") ++count;
  }
  closedir(directory);
  return count;
}
} // namespace

int main(int argc, char** argv)
{
  std::uint64_t seed = 0;
  try
  {
    seed = parseSeed(argc, argv);
  }
  catch(const std::exception& error)
  {
    std::fprintf(stderr, "synthetic environment option error: %s\n",
                 error.what());
    return 64;
  }

  const bool protocol_check = hasFlag(argc, argv, "--syntheticProtocolCheck");
  const bool evaluation_check =
    optionValue(argc, argv, "--nEvalEpisodes", "0") != "0";
  const std::string audit_directory =
    optionValue(argc, argv, "--learnerAuditDir", "none");
  if(protocol_check && audit_directory == "none")
  {
    std::fprintf(stderr,
      "synthetic protocol check requires --learnerAuditDir\n");
    return 64;
  }

  int finalized = 0;
  int result = 0;
  {
    ibamr_smarties::CouplingDriver driver(argc, argv);
    int world_rank = 0;
    MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);

    long updates_before = 0;
    long initialized_before = 0;
    long final_before = 0;
    if(protocol_check && world_rank == 0)
    {
      const std::string log = audit_directory + "/learner_audit.log";
      updates_before = countAuditStage(log, "update");
      initialized_before = countAuditStage(log, "initialized");
      final_before = countAuditStage(log, "final");
    }

    const auto callback = [seed, protocol_check](
      smarties::Communicator* const comm,
      const MPI_Comm environment_comm,
      int, char**) {
      runSyntheticEnvironment(comm, environment_comm, seed, protocol_check);
    };
    result = driver.run(callback);
    if(result != 0) return result;

    if(protocol_check)
    {
      const int local_terminal = protocol_report.episodes > 0 ? 1 : 0;
      int terminal_workers = 0;
      MPI_Allreduce(&local_terminal, &terminal_workers, 1, MPI_INT, MPI_SUM,
                    MPI_COMM_WORLD);
      if(world_rank == 0)
      {
        const std::string log = audit_directory + "/learner_audit.log";
        const long updates = countAuditStage(log, "update") - updates_before;
        const long initialized =
          countAuditStage(log, "initialized") - initialized_before;
        const long final = countAuditStage(log, "final") - final_before;
        const unsigned initial_files =
          directoryEntryCount(audit_directory + "/initial");
        const unsigned final_files =
          directoryEntryCount(audit_directory + "/final");
        const bool training_failure = !evaluation_check &&
          (updates != 2 || initialized < 1 || final < 1 ||
           initial_files == 0 || final_files == 0);
        const bool evaluation_failure = evaluation_check && updates != 0;
        if(training_failure || evaluation_failure || terminal_workers < 1)
          result = 96;
        std::printf("SMARTIES_SYNTHETIC_PROTOCOL_CHECK updates=%ld "
                    "initialized=%ld final=%ld terminal_workers=%d "
                    "initial_files=%u final_files=%u status=%s\n",
                    updates, initialized, final, terminal_workers,
                    initial_files, final_files,
                    result == 0 ? "PASS" : "FAIL");
      }
      MPI_Bcast(&result, 1, MPI_INT, 0, MPI_COMM_WORLD);
      if(result != 0) return result;
    }

    MPI_Finalized(&finalized);
    if(finalized != 0) return 93;
    if(world_rank == 0)
      std::puts("COUPLING_DRIVER_RETURNED_MPI_ACTIVE");
  }

  MPI_Finalized(&finalized);
  if(finalized == 0) return 94;
  std::puts("COUPLING_DRIVER_DESTROYED_MPI_FINALIZED");
  return result;
}
