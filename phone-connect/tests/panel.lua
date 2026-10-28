local directory = arg[1] or "phone-connect"
local values, watchers, tree, commands = {}, {}, nil, {}
local reads = {}
local function noop() end
local api = {
    state={get=function(k) reads[k]=(reads[k] or 0)+1; return values[k] end,
           set=function(k,v) values[k]=v; if k=="pc.cmd" then table.insert(commands,v) end end,
           watch=function(k,cb) watchers[k]=cb end},
    nowMs=function() return 100000 end,
    formatTime=function() return "Oct 28 · 12:00" end,
    getConfig=function(k) return k=="enable_clipboard_action" end,
    fileExists=function() return false end,
    copyToClipboard=noop,
    json={decode=function(v) return v end},
}
local ui=setmetatable({}, {__index=function(_,kind)
    return function(props,children)
        for i,v in ipairs(children or {}) do assert(type(v)=="table",kind.." child "..i) end
        return {kind=kind,props=props,children=children or {}}
    end
end})
local env=setmetatable({noctalia=api,ui=ui,panel={render=function(t) tree=t end,close=noop}},{__index=_G})
local modules={}
env.require=function(path)
    if not modules[path] then modules[path]=assert(loadfile(directory.."/"..path,"t",env))() end
    return modules[path]
end
local Model=env.require('./messaging-model.luau')
local d=Model.device();d.connected=true;d.capabilities={messages=true,contacts=true,notifications=true}
d.contacts={{id="alex",name="Alex",numbers={"123","456"},search="alex 123 456"}}
local m={id="1",thread="42",date=1000,body="hello 👋",addresses={"123"},attachments=1}
Model.reduce(d,{type="message",message=m})
values['pc.devices']={a={id="a",name="Phone with a very long name",isPaired=true,isReachable=true},b={id="b",name="Phone B",isPaired=true,isReachable=true}}
values['pc.order']={"a","b"};values['pc.selected']="a"
values['pc.messaging']={devices={a=d},pending={},results={}}
values['pc.trTable']={} -- Translation keys make the callbacks easy to locate.
assert(loadfile(directory..'/panel.luau','t',env))()
local function find(predicate,node)
    node=node or tree
    if predicate(node) then return node end
    for _,child in ipairs(node.children) do local result=find(predicate,child);if result then return result end end
end
local function text(s) return assert(find(function(n) return n.props.text==s end),s) end
local function key(s) return assert(find(function(n) return n.props.key==s end),s) end
env.onOpen()
assert(commands[#commands].op=='sync')
key('thread:a:42').props.onClick()
assert(commands[#commands].op=='history' and commands[#commands].start==0)
local composer=key('composer-row:a:sms:42')
assert(composer.props.height==40,'Empty composer must use one compact row')
local input=key('a:sms:42:input:0')
input.props.onChange('Keep this draft\nSecond line')
assert(key('composer-row:a:sms:42').props.height==58,'Multiline draft must grow')
assert(text('panel.sms_send').props.enabled)
text('panel.sms_send').props.onClick()
assert(commands[#commands].text=='Keep this draft\nSecond line')
assert(values['pc.drafts']['a:sms:42'].text=='Keep this draft\nSecond line','UI must not clear an unacknowledged send')
values['pc.messaging'].pending['a:sms:42']={}
env.render();assert(not text('panel.sms_send').props.enabled)
values['pc.messaging'].pending={}
text('chat.tab_contacts').props.onClick()
assert(text('123') and text('456'))
key('contacts-search:a').props.onChange('unknown')
assert(text('chat.no_results'))
text('chat.tab_device').props.onClick()
local before=#commands
text('action.unpair').props.onClick()
assert(#commands==before,'Unpair first click must only ask for confirmation')
text('chat.cancel').props.onClick()
env.onClose();env.onOpen()
assert(values['pc.drafts']['a:sms:42'].text=='Keep this draft\nSecond line')
-- Switching a device must not seed another device's composer with this draft.
local select=find(function(n) return n.kind=='select' end)
select.props.onChange('1')
assert(commands[#commands].device=='b')
-- Preview cannot dispatch any phone operation, including destructive controls.
env.onIpc('preview',{devices=values['pc.devices'],order={'a'},selected='a',thread='42',messaging=values['pc.messaging']})
before=#commands
text('panel.sms_send').props.onClick()
env.onIpc('view',{tab='device'})
text('action.unpair').props.onClick();text('action.unpair').props.onClick()
assert(#commands==before,'Preview must not send commands')
env.onClose()
-- A real address book must not create an unbounded native tree or repeatedly
-- decode the shared translation table. This caused native callback timeouts.
for i=2,1000 do
    table.insert(d.contacts,{id=tostring(i),name='Person '..i,numbers={tostring(i)},search='person '..i})
end
env.onOpen();env.onIpc('view',{tab='contacts'})
key('contacts-search:a').props.onChange('')
reads['pc.trTable']=0;env.render()
assert(reads['pc.trTable']==1,'Translations must be decoded once per render')
assert(text('1 / 40'))
assert(not find(function(n) return n.props.key=='contact:a:26' end))
text('chat.next').props.onClick()
assert(key('contact:a:26') and text('2 / 40'))
text('chat.previous').props.onClick();assert(text('1 / 40'))
key('contacts-search:a').props.onChange('person 1000')
assert(key('contact:a:1000'),'Search must cover contacts outside the current page')
assert(not find(function(n) return n.props.text=='chat.next' end))
-- Keep long histories bounded while allowing both directions through loaded pages.
for i=2,121 do
    Model.reduce(d,{type='message',message={id=tostring(i),thread='42',date=i*1000,
        body='Loaded message '..i,addresses={'123'},attachments=0}})
end
env.onIpc('view',{tab='messages',compact=false})
key('thread:a:42').props.onClick()
assert(key('message:a:42:121'))
assert(not find(function(n) return n.props.key=='message:a:42:71' end))
before=#commands;text('chat.load_older').props.onClick()
assert(#commands==before,'Paging cached history must not refetch it')
assert(key('message:a:42:71'))
assert(not find(function(n) return n.props.key=='message:a:42:121' end))
text('chat.newer_messages').props.onClick();assert(key('message:a:42:121'))
print('Panel interaction regressions passed')
