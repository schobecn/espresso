#ifndef OBSERVABLES_FORCEDENSITYPROFILE_HPP
#define OBSERVABLES_FORCEDENSITYPROFILE_HPP

#include "ProfileObservable.hpp"
#include "partCfg.hpp"
#include <vector>

namespace Observables {

class ForceDensityProfile : public ProfileObservable {
public:
  virtual int n_values() const override { return 3 * xbins * ybins * zbins; }
  virtual int actual_calculate() override {
    double bin_volume =
        (maxx - minx) * (maxy - miny) * (maxz - minz) / xbins / ybins / zbins;

    for (int id : ids) {
      auto const ppos = folded_position(partCfg[id]);

      int binx = (int)floor(xbins * (ppos[0] - minx) / (maxx - minx));
      int biny = (int)floor(ybins * (ppos[1] - miny) / (maxy - miny));
      int binz = (int)floor(zbins * (ppos[2] - minz) / (maxz - minz));
      if (binx >= 0 && binx < xbins && biny >= 0 && biny < ybins && binz >= 0 &&
          binz < zbins) {
        for (int dim = 0; dim < 3; dim++)
          last_value[3 * (binx * ybins * zbins + biny * zbins + binz) + dim] +=
              partCfg[id].f.f[dim] / bin_volume;
      }
    }
    return 0;
  }
};

} // Namespace Observables

#endif
