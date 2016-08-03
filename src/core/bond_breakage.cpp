#include <vector>
#include <tuple>
#include "interaction_data.hpp"
#include "particle_data.hpp"
#include "bond_breakage.hpp" 
#include <functional>

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
    for (auto h : handlers) {
      h(std::get<0>(p),std::get<1>(p),std::get<2>(p));
    }
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

void print_queue_entry(int t, int p1, int p2)
{
  printf("Bond breakage: Type=%d, id1=%d, id2=%d\n",t,p1,p2);
}

const std::map<std::string, BreakageHandler> available_bond_breakage_handlers() 
{
  typedef std::map<std::string, BreakageHandler> result_type;
  result_type res;
  typedef result_type::value_type val;
  res.insert(val(std::string("break_simple_pair_bond"),break_simple_pair_bond));
  res.insert(val(std::string("print_queue_entry"),print_queue_entry));
  return res;
}

bool BondBreakage::add_handler_by_name(const std::string& n) {
  // Find the handler with the given name
  
  if (available_bond_breakage_handlers().count(n)==0)
    return false;

  // Else, add the handler to the list of active handlers
  handlers.push_back(available_bond_breakage_handlers().at(n));
  return true;
}

const std::vector<std::string> BondBreakage::active_handlers_by_name() {
  std::vector<std::string> res;

  // Iterate over active handlers
  for (auto h : handlers) {
    bool found=false;
    for (auto i: available_bond_breakage_handlers()) {
      printf("h:%p; i:%s,%p\n",h,i.first.c_str(),i.second);
      if (i.second ==h) {
        found=true;
        res.push_back(i.first);
        break;
      }
    }
    if (!found) 
      res.push_back(std::string("Unknown"));
  }
  return res;
}

const std::vector<std::string> available_bond_breakage_handlers_by_name() {
  std::vector<std::string> res;
  for (auto h : available_bond_breakage_handlers()) {
      res.push_back(std::string(h.first));
  }
  return res;

}

