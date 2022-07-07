local files  = require 'files'
local define = require 'proto.define'
local config = require 'config'
local await  = require 'await'
local vm     = require "vm.vm"
local util   = require 'utility'
local diagd  = require 'proto.diagnostic'

-- 把耗时最长的诊断放到最后面
local diagSort = {
    ['redundant-value']      = 100,
    ['not-yieldable']        = 100,
    ['deprecated']           = 100,
    ['undefined-field']      = 110,
    ['redundant-parameter']  = 110,
    ['cast-local-type']      = 120,
    ['assign-type-mismatch'] = 120,
    ['param-type-mismatch']  = 120,
}

local diagList = {}
for k in pairs(define.DiagnosticDefaultSeverity) do
    diagList[#diagList+1] = k
end
table.sort(diagList, function (a, b)
    return (diagSort[a] or 0) < (diagSort[b] or 0)
end)

local sleepRest = 0.0

---@async
local function checkSleep(uri, passed)
    local speedRate = config.get(uri, 'Lua.diagnostics.workspaceRate')
    if speedRate <= 0 or speedRate >= 100 then
        return
    end
    local sleepTime = passed * (100 - speedRate) / speedRate
    if sleepTime + sleepRest < 0.001 then
        sleepRest = sleepRest + sleepTime
        return
    end
    sleepRest = sleepTime + sleepRest
    sleepTime = sleepRest
    if sleepTime > 0.1 then
        sleepTime = 0.1
    end
    local clock = os.clock()
    await.sleep(sleepTime)
    local sleeped = os.clock() - clock

    sleepRest = sleepRest - sleeped
end

---@param uri  uri
---@param name string
---@return string
local function getSeverity(uri, name)
    local severity =   config.get(uri, 'Lua.diagnostics.severity')[name]
                    or define.DiagnosticDefaultSeverity[name]
    if severity:sub(-1) == '!' then
        return severity:sub(1, -2)
    end
    local groupSeverity = config.get(uri, 'Lua.diagnostics.groupSeverity')
    local groups = diagd.getGroups(name)
    local groupLevel = 999
    for _, groupName in ipairs(groups) do
        local gseverity = groupSeverity[groupName]
        if gseverity and gseverity ~= 'Fallback' then
            groupLevel = math.min(groupLevel, define.DiagnosticSeverity[gseverity])
        end
    end
    if groupLevel == 999 then
        return severity
    end
    for severityName, level in pairs(define.DiagnosticSeverity) do
        if level == groupLevel then
            return severityName
        end
    end
    return severity
end

---@param uri  uri
---@param name string
---@return string
local function getStatus(uri, name)
    local status = config.get(uri, 'Lua.diagnostics.neededFileStatus')[name]
                or define.DiagnosticDefaultNeededFileStatus[name]
    if status:sub(-1) == '!' then
        return status:sub(1, -2)
    end
    local groupStatus = config.get(uri, 'Lua.diagnostics.groupFileStatus')
    local groups = diagd.getGroups(name)
    local groupLevel = 0
    for _, groupName in ipairs(groups) do
        local gstatus = groupStatus[groupName]
        if gstatus and gstatus ~= 'Fallback' then
            groupLevel = math.max(groupLevel, define.DiagnosticFileStatus[gstatus])
        end
    end
    if groupLevel == 0 then
        return status
    end
    for statusName, level in pairs(define.DiagnosticFileStatus) do
        if level == groupLevel then
            return statusName
        end
    end
    return status
end

---@async
---@param uri uri
---@param name string
---@param isScopeDiag boolean
---@param response async fun(result: any)
local function check(uri, name, isScopeDiag, response)
    local disables = config.get(uri, 'Lua.diagnostics.disable')
    if util.arrayHas(disables, name) then
        return
    end
    local severity = getSeverity(uri, name)
    local status   = getStatus(uri, name)

    if status == 'None' then
        return
    end

    if status == 'Opened' and not files.isOpen(uri) then
        return
    end

    local level = define.DiagnosticSeverity[severity]
    local clock = os.clock()
    local mark = {}
    ---@async
    require('core.diagnostics.' .. name)(uri, function (result)
        if vm.isDiagDisabledAt(uri, result.start, name) then
            return
        end
        if result.start < 0 then
            return
        end
        if mark[result.start] then
            return
        end
        mark[result.start] = true

        result.level = level or result.level
        result.code  = name
        response(result)
    end, name)
    local passed = os.clock() - clock
    if passed >= 0.5 then
        log.warn(('Diagnostics [%s] @ [%s] takes [%.3f] sec!'):format(name, uri, passed))
    end
    if isScopeDiag then
        checkSleep(uri, passed)
    end
    if DIAGTIMES then
        DIAGTIMES[name] = (DIAGTIMES[name] or 0) + passed
    end
end

---@async
---@param uri uri
---@param isScopeDiag boolean
---@param response async fun(result: any)
---@param checked? async fun(name: string)
return function (uri, isScopeDiag, response, checked)
    local ast = files.getState(uri)
    if not ast then
        return nil
    end

    for _, name in ipairs(diagList) do
        await.delay()
        check(uri, name, isScopeDiag, response)
        if checked then
            checked(name)
        end
    end
end
