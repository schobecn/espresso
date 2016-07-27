#include "boost/signals2.hpp"
#include <vector>
#include <tuple>
#include <string>

// Handlers which actually remove the bond. Args: bond type, particle ids
typedef boost::signals2::signal<void(int,int,int)> BreakageHandler;


class BondBreakage {
  public:
    // Queue bonds to break
    std::vector<std::tuple<int,int,int>> queue;
    // Signal called on each bond to be removed in process_queue()
    BreakageHandler handlers;
  
    void process_queue();
};

// Get reference to active instance
BondBreakage& bond_breakage();

// Hander to break simple pair bonds 
void break_simple_pair_bond(int t, int p1, int p2);

void initialize_bond_breakage();
const std::map<std::string, std::function<void(int,int,int)>> available_bond_breakage_handlers();
