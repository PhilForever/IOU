-- Native item link viewer fields are comparison context, not stored identity.
local support=assert(IOU_TEST_SUPPORT,"Run after test_iou.lua.")
local copy,same=support.Copy,support.Same
local results={}
local function test(name,run)
    local ok,err=pcall(run);if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function session()
    local state=support.Session({name="Amber",fullName="Amber Stone"})
    local api=state.api;assert(api.Initialize());assert(api.SharedService.Initialize());assert(api.TradeService.Initialize())
    return state,api
end
local function payload(level,spec,changes)
    local fields={2589,0,0,0,0,0,0,0,level or 0,spec or 0,0,0,0}
    local highest=#fields
    for index,value in pairs(changes or {}) do fields[index]=value;highest=math.max(highest,index) end
    for index=1,highest do fields[index]=tostring(fields[index] or 0) end
    return "item:"..table.concat(fields,":")
end
local function link(key) return "|cffffffff|H"..key.."|h[Linen Cloth]|h|r" end
local function side(money,key,quantity)
    return {money=money or 0,items=key and {{itemID=2589,name="Linen Cloth",link=link(key),quantity=quantity or 2}} or {}}
end
local function transfer(direction,key,quantity,money)
    local value={peer="Birch Vale",incoming=side(),outgoing=side()}
    value[direction=="owed" and "incoming" or "outgoing"]=side(money,key,quantity)
    return value
end
local function add(api,direction,kind,amount,label)
    return assert(api.Add({player="Birch Vale",direction=direction,kind=kind,amount=amount,label=label or "",note="",due=0}))
end
local function shared(api,direction,key,personalID)
    local C=api.SharedCodec
    local terms={protocol=3,kind="ITEM_OBLIGATION",proposer="Amber Stone",recipient="Birch Vale",
        debtor=direction=="owed" and "Birch Vale" or "Amber Stone",
        creditor=direction=="owed" and "Amber Stone" or "Birch Vale",
        amountCopper=10,dueUTC=0,note="",itemKey=assert(C.CanonicalItem(key)),itemName="Linen Cloth"}
    local overview={localName="Amber Stone",offers={{offerId="context-shared",role="proposer",state="COMMITTED",
        delivery="PEER_RECEIPT_OBSERVED",terms=assert(C.CanonicalTerms(terms))}},
        balances={["context-shared"]={confirmed=true,remainingCopper=10}}}
    if personalID then overview.links={[personalID]="context-shared"};overview.linkBases={[personalID]=0} end
    return overview
end

test("item context comparison ignores only native link level and specialization",function()
    local _,api=session();local M,C=api.TradeMatching,api.SharedCodec
    local old,new=payload(13,71),payload(24,72)
    assert(M.EquivalentItems(link(old),link(new)))
    assert(M.EquivalentItems(old,payload(0,0)))
    assert(M.EquivalentItems("item:2589",new))
    assert(M.ItemKey(old)~=M.ItemKey(new));assert(C.CanonicalItem(old)~=C.CanonicalItem(new))
    equal(M.ItemKey(old),C.CanonicalItem(old))
end)

test("item context comparison rejects malformed links and keeps real variants distinct",function()
    local _,api=session();local M=api.TradeMatching
    for _,index in ipairs({2,3,4,5,6,7,8,11,12,13,14,15,16}) do
        local variant=payload(24,72,{[index]=index==7 and -17 or 1})
        assert(not M.EquivalentItems(payload(13,71),variant),"ignored actual item field "..index)
    end
    for _,bad in ipairs({"", "Linen Cloth", "item:2589:x", "item:2589:1.5", "|Hitem:2589|hbroken", "item:0"}) do
        assert(not M.EquivalentItems(bad,payload(13,71)))
    end
    assert(not M.EquivalentItems({},payload(13,71)))
end)

test("personal gold and item repayments match both directions across viewer contexts",function()
    for _,direction in ipairs({"owed","owe"}) do
        local _,api=session();local M=api.TradeMatching
        local original,observed=payload(13,71),payload(24,72)
        local gold=add(api,direction,"money",10000)
        local item=add(api,direction,"item",10,link(original))
        local result=assert(M.Plan(api.GetLedger(),nil,transfer(direction,observed,2,3000)))
        equal(#result.actions,2);equal(#result.pending,0)
        equal(result.actions[1].entryID,gold.id);equal(result.actions[1].amount,3000)
        equal(result.actions[2].entryID,item.id);equal(result.actions[2].amount,2)
        equal(result.actions[2].itemKey,M.ItemKey(observed))
        equal(result.actions[2].label,link(original))
    end
end)

test("Shared item candidates compare viewer context without dropping confirmation",function()
    for _,direction in ipairs({"owed","owe"}) do
        local _,api=session();local old,new=payload(13,71),payload(24,72)
        local result=assert(api.TradeMatching.Plan(api.GetLedger(),shared(api,direction,old),transfer(direction,new)))
        equal(#result.actions,0);equal(#result.pending,1)
        equal(result.pending[1].reason,"shared_confirmation")
        equal(result.pending[1].candidates[1].source,"shared")
        equal(result.pending[1].itemKey,api.TradeMatching.ItemKey(new))
    end
end)

test("linked personal and Shared item copies pay once across viewer contexts",function()
    for _,direction in ipairs({"owed","owe"}) do
        local _,api=session();local old,new=payload(13,71),payload(24,72)
        local entry=add(api,direction,"item",10,link(old))
        local result=assert(api.TradeMatching.Plan(api.GetLedger(),shared(api,direction,old,entry.id),transfer(direction,new)))
        equal(#result.actions,1);equal(result.actions[1].entryID,entry.id)
        equal(result.actions[1].amount,2);equal(#result.pending,0)
    end
end)

test("actual item variants still require review for personal and Shared balances",function()
    for _,direction in ipairs({"owed","owe"}) do
        local _,api=session();local old=payload(13,71)
        local variant=payload(24,72,{[7]=-17})
        add(api,direction,"item",10,link(old))
        local result=assert(api.TradeMatching.Plan(api.GetLedger(),nil,transfer(direction,variant)))
        equal(#result.actions,0);equal(result.pending[1].reason,"item_identity")
        result=assert(api.TradeMatching.Plan(api.Ledger.New(),shared(api,direction,old),transfer(direction,variant)))
        equal(#result.actions,0);equal(result.pending[1].reason,"item_identity")
    end
end)

test("old trade receipt keys validate unchanged after comparison context is ignored",function()
    local state,api=session();local T,M=api.TradeService,api.TradeMatching
    local old,new=payload(13,71),payload(24,72)
    local entry=add(api,"owed","item",10,link(old))
    local first=transfer("owed",old,2);first.id=assert(T.NewSessionID())
    local receipt=assert(T.Record(first));equal(receipt.status,"applied")
    local journal=state.env.IOUDB.tradesByCharacter[api.Character()]
    local evidence=copy(journal.receipts[1]);assert(T.Validate(journal))
    equal(evidence.applications[1].itemKey,M.ItemKey(old))
    local second=transfer("owed",new,3);second.id=assert(T.NewSessionID())
    local nextReceipt=assert(T.Record(second));equal(nextReceipt.status,"applied")
    equal(api.Ledger.Balance(api.GetLedger().entries[entry.id]),5)
    assert(T.Validate(journal));assert(T.Validate(state.env.IOUDB.tradesByCharacter[api.Character()]))
    assert(same(evidence,state.env.IOUDB.tradesByCharacter[api.Character()].receipts[1]))
    equal(nextReceipt.applications[1].itemKey,M.ItemKey(new))
end)

return results
