-- Default paths and shell-free argv, using mocks only.
local watch,argv={}
noctalia={getConfig=function() return "" end,pluginDir=function() return "/home/Other User/plugins/nectarlink" end,
  json={decode=function(v) return v end,encode=function(v) return v end},
  state={watch=function(k,cb) watch[k]=cb end},runAsync=function(v) argv=v end}
dofile('service.luau')
watch['nl.command']({action='open'})
assert(type(argv)=='table' and argv[1]=='python')
assert(argv[2]=='/home/Other User/plugins/nectarlink/colors.py' and argv[3]=='open' and argv[4]=='nectarlink-desktop')
print('PASS: portable bundled helper, PATH executable, no shell interpolation')
