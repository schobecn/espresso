#include "boost/signals2.hpp"
#include <vector>
#include <tuple>
#include <string>
#include "boost/bimap.hpp"

// Handlers which actually remove the bond. Args: bond type, particle ids
//typedef std::function<void(int,int,int)> BreakageHandler;
typedef void (*BreakageHandler)(int,int,int);


class BondBreakage {
  public:
    // Queue bonds to break
    std::vector<std::tuple<int,int,int>> queue;
    // Vector containing the active bond breakage handlers 
    // Note: Not using boost:signals2, because it doesn't seem to iterate 
    // active slots for other purposes than calling. 
    // We need to get the names of connected slots in the script interface
    std::vector<BreakageHandler> handlers;

    bool add_handler_by_name(const std::string& n);
    const std::vector<std::string> active_handlers_by_name();
  
    void process_queue();


};

// Get reference to active instance
BondBreakage& bond_breakage();

// Hander to break simple pair bonds 
void break_simple_pair_bond(int t, int p1, int p2);

void initialize_bond_breakage();
const std::map<std::string, BreakageHandler> available_bond_breakage_handlers();
const std::vector<std::string> available_bond_breakage_handlers_by_name(); 
