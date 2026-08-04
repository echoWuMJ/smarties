#include "CouplingDriver.h"
#include "EelSmartiesAdapter.h"

int main(int argc, char** argv)
{
  ibamr_smarties::CouplingDriver driver(argc, argv);
  return driver.run(ibamr_smarties::eel2d::runSmokeEpisode);
}
