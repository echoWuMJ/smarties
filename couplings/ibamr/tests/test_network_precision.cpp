#include "smarties/Settings/Definitions.h"

#include <cstdio>

#ifndef SMARTIES_EXPECT_NNREAL_BYTES
#error SMARTIES_EXPECT_NNREAL_BYTES must be defined
#endif

int main()
{
  const int bytes = static_cast<int>(sizeof(smarties::nnReal));
#ifdef SINGLE_PREC
  const int single_macro = 1;
#else
  const int single_macro = 0;
#endif
  std::printf("SMARTIES_NETWORK_PRECISION bytes=%d single_macro=%d\n",
              bytes,
              single_macro);
  return bytes == SMARTIES_EXPECT_NNREAL_BYTES ? 0 : 1;
}
