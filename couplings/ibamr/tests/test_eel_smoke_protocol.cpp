#include "CouplingDriver.h"
#include "EelSmartiesAdapter.h"

#include <mpi.h>

#include <cstdio>

int main(int argc, char** argv)
{
    int finalized = 0;
    {
        ibamr_smarties::CouplingDriver driver(argc, argv);
        const int status = driver.run(ibamr_smarties::eel2d::runSmokeEpisode);
        if (status != 0) return status;

        const auto report = ibamr_smarties::eel2d::lastSmokeProtocolReport();
        const int local_terminal = report.terminal_sent ? 1 : 0;
        const int local_one_step =
          report.terminal_sent && report.completed_steps == 1 ? 1 : 0;
        int terminal_count = 0;
        int one_step_count = 0;
        MPI_Allreduce(&local_terminal, &terminal_count, 1, MPI_INT, MPI_SUM,
                      MPI_COMM_WORLD);
        MPI_Allreduce(&local_one_step, &one_step_count, 1, MPI_INT, MPI_SUM,
                      MPI_COMM_WORLD);
        if (terminal_count != 1 || one_step_count != 1) return 95;

        MPI_Finalized(&finalized);
        if (finalized != 0) return 93;
        std::puts("COUPLING_DRIVER_RETURNED_MPI_ACTIVE");
    }

    MPI_Finalized(&finalized);
    if (finalized == 0) return 94;
    std::puts("COUPLING_DRIVER_DESTROYED_MPI_FINALIZED");
    return 0;
}
