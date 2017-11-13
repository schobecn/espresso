from .script_interface import ScriptInterfaceHelper
from .utils import handle_errors, to_str
from .interactions import BondedInteraction,BondedInteractions



class CollisionDetection(ScriptInterfaceHelper):
    """Inteface to the collision detection / dynamic binding."""

    _so_name = "CollisionDetection::CollisionDetection"

    def __init__(self,*args,**kwargs):
        # If no mode is specified at construction, use off.
        if "mode" not in kwargs:
            kwargs["mode"]="off"
        super(type(self),self).__init__(*args,**kwargs)
        

    def validate(self):
        return self.call_method("validate")
    
    # Do not allow setting of individual attributes
    def __setattr__(self,*args,**kwargs):
        raise Exception("Please et all parameters at once via collision_detection.set_params()")

    # Override to call validat after parameter update
    def set_params(self, **kwargs):
        if not ("mode" in kwargs):
            raise Exception("Collision mode must be specified via the mode keyword argument")
        
        # Completeness of parameter set
        if not (set(kwargs.keys()) == set(self._params_for_mode(kwargs["mode"]))):
            raise Exception("Parameter set does not match mode. ",kwargs["mode"],"requries ",self._params_for_mode(kwargs["mode"]))

        # Mode
        kwargs["mode"]=self._int_mode[kwargs["mode"]]

        # Convert bonds to bond ids
        for name in [ "bond_centers","bond_vs","bond_three_particle_binding"]:
            if name in kwargs:
                if isinstance(kwargs[name],BondedInteraction):
                    kwargs[name]=kwargs[name]._bond_id
        super(type(self),self).set_params(**kwargs)
        self.validate()
        handle_errors("Validation of collision detection failed")

    def get_parameter(self,name):
        res=super(type(self),self).get_parameter(name)
        return self._convert_param(name,res)
    
    def get_params(self):
        res=super(type(self),self).get_params()
        for k in res.keys():
            res[k]=self._convert_param(k,res[k])
        return res


    def _convert_param(self,name,value):
        # Py3: Cast from binary to normal string. Don't understand, why a
        # binary string can even occur, here, but it does.
        name=to_str(name)
        # Convert mode parameter into python enum
        res=value
        if name == "mode":
            res=self._str_mode(value)
        
        # Convert bond parameters from bond ids to into BondedInteractions
        if name in [ "bond_centers","bond_vs","bond_three_particle_binding"]:
            if value==-1: # Not defined
                res=None
            else:
                res=BondedInteractions()[value]
        return res
    
    def _params_for_mode(self,mode):
        if mode == "off":
            return ("mode",)
        if mode == "bind_centers":
            return ("mode","bond_centers","distance")
        if mode == "bind_at_point_of_collision": 
            return ("mode","bond_centers","bond_vs","part_type_vs","distance","vs_placement")
        if mode == "glue_to_surface":
            return ("mode","bond_centers","bond_vs","part_type_vs","part_type_to_be_glued","part_type_to_attach_vs_to","part_type_after_glueing","distance","distance_glued_particle_to_vs")
        if mode == "bind_three_particles":
            return ("mode","bond_centers","distance","bond_three_particles","three_particle_binding_angle_resolution")
        raise Exception("Mode not hanled: "+mode.__str__())
            
            
    
    _int_mode={
        "off":0,
        "bind_centers":2,
        "bind_at_point_of_collision":4,
        "glue_to_surface":8,
        "bind_three_particles":16}
    
    def _str_mode(self,int_mode):
        for key in self._int_mode:
            if self._int_mode[key] == int_mode:
                return key
        raise Exception("Unknown integer collision mode %d" % int_mode)
    
    
