#include "boost/signals2.hpp"
#include <vector>
#include <tuple>
#include "interaction_data.hpp"
#include "particle_data.hpp"
#include "bond_breakage.hpp" 

// Active instance 
std::unique_ptr<BondBreakage> bb;

void initialize_bond_breakage() {
  bb=std::unique_ptr<BondBreakage>(new BondBreakage());
}

BondBreakage& bond_breakage()
{
 return *bb;
}


void BondBreakage::process_queue() {
  for (auto p : queue) {
    handlers(std::get<0>(p),std::get<1>(p),std::get<2>(p));
  }
  queue.clear();
}


void break_simple_pair_bond(int t, int p1, int p2)
{
  // Holds data for local_change_bond()
  int bond[2];
  bond[0]=t;

  // The bond can be on any of the two particles
  if (bond_exists(local_particles[p1],local_particles[p2],t)) {
    // Delete the bond
    bond[1]=p2;
    local_change_bond(p1,bond,1);
  }
  if (bond_exists(local_particles[p2],local_particles[p1],t)) {
    // Delete the bond
    bond[1]=p1;
    local_change_bond(p2,bond,1);
  }
}


const std::map<std::string, std::function<void(int,int,int)>> available_bond_breakage_handlers() 
{
  return std::map<std::string, std::function<void(int,int,int)>>({ 
    { "break_simple_pair_bond",&break_simple_pair_bond}
  });
}
