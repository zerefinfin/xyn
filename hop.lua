task.wait(5)

-- Configurações GitHub
local SERVERS_URL = "https://raw.githubusercontent.com/zerefinfin/xyn/refs/heads/main/servers.json"
local ACCOUNTS_URL = "https://raw.githubusercontent.com/zerefinfin/xyn/refs/heads/main/accounts.json"

-- Configurações locais
local PLACE_ID = tostring(game.PlaceId)
local PLAYER_ID = tostring(game:GetService("Players").LocalPlayer.UserId)
local PLAYER_NAME = game:GetService("Players").LocalPlayer.Name
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Arquivos locais (backup/fallback)
local USED_FILE = "used_servers.json"
local STATE_FILE = "hop_state.json"
local PROTECT = 180

-- CACHE: Evita requisições HTTP excessivas
local CACHE_DURATION = 120  -- AUMENTADO: 120s (2min) para economizar banda com muitos Roblox
local servers_cache = nil
local accounts_cache = nil
local last_servers_fetch = 0
local last_accounts_fetch = 0

-- Funções utilitárias
local function fexists(n)
    local ok = pcall(function() return readfile(n) end)
    return ok
end

local function jload(n)
    if not readfile or not writefile then return {} end
    if not fexists(n) then
        writefile(n, "{}")
        return {}
    end
    local ok, d = pcall(function() return HttpService:JSONDecode(readfile(n)) end)
    return ok and type(d) == "table" and d or {}
end

local function jsave(n, d)
    if writefile then
        writefile(n, HttpService:JSONEncode(d))
    end
end

-- CARREGA DO GITHUB com CACHE (reduz requisições)
local function loadServers()
    local now = os.time()
    
    -- Retorna cache se ainda válido
    if servers_cache and (now - last_servers_fetch) < CACHE_DURATION then
        return servers_cache
    end
    
    print("☁️ Carregando servidores do GitHub...")
    local ok, r = pcall(function() return game:HttpGet(SERVERS_URL) end)
    if not ok then
        print("❌ Erro ao carregar do GitHub:", r)
        -- Fallback: retorna cache antigo se existir
        if servers_cache then
            print("🔄 Usando cache antigo...")
            return servers_cache
        end
        print("🔄 Tentando arquivo local...")
        local localData = jload("servers.json")
        return localData[PLACE_ID] and {[PLACE_ID] = localData[PLACE_ID]} or nil
    end
    local ok2, d = pcall(function() return HttpService:JSONDecode(r) end)
    if not ok2 then
        print("❌ Erro ao decodificar JSON do GitHub:", d)
        return servers_cache  -- Retorna cache se falhar
    end
    
    -- Atualiza cache
    servers_cache = d
    last_servers_fetch = now
    print("✅ Servidores carregados do GitHub!")
    return d
end

local function loadAccounts()
    local now = os.time()
    
    -- Retorna cache se ainda válido
    if accounts_cache and (now - last_accounts_fetch) < CACHE_DURATION then
        return accounts_cache
    end
    
    print("☁️ Carregando contas do GitHub...")
    local ok, r = pcall(function() return game:HttpGet(ACCOUNTS_URL) end)
    if not ok then
        print("❌ Erro ao carregar contas:", r)
        return accounts_cache or {}  -- Retorna cache ou vazio
    end
    local ok2, d = pcall(function() return HttpService:JSONDecode(r) end)
    if not ok2 then
        print("❌ Erro ao decodificar contas:", d)
        return accounts_cache or {}
    end
    
    -- Atualiza cache
    accounts_cache = d
    last_accounts_fetch = now
    return d
end

-- Sistema de controle
local function justHoppedHere()
    local s = jload(STATE_FILE)
    if not s.last_target_jobid then return false end
    if s.last_target_jobid ~= game.JobId then return false end
    if not s.last_hop_time then return false end
    return (os.time() - s.last_hop_time) <= PROTECT
end

local function isUsed(id, used)
    for _, x in ipairs(used) do
        if x == id then return true end
    end
    return false
end

local function markUsed(id)
    local used = jload(USED_FILE)
    used[PLACE_ID] = used[PLACE_ID] or {}
    table.insert(used[PLACE_ID], id)
    jsave(USED_FILE, used)
end

local function removeUsed(id)
    local used = jload(USED_FILE)
    if used[PLACE_ID] then
        for i, v in ipairs(used[PLACE_ID]) do
            if v == id then
                table.remove(used[PLACE_ID], i)
                break
            end
        end
        jsave(USED_FILE, used)
    end
end

local function markTarget(id)
    jsave(STATE_FILE, {
        last_target_jobid = id,
        last_hop_time = os.time()
    })
end

-- Pega servidor disponível do GitHub
local function getServer()
    local all = loadServers()
    if not all or not all[PLACE_ID] then
        print("❌ Nenhum servidor disponível para este jogo no GitHub")
        return nil
    end

    local list = all[PLACE_ID]
    local usedData = jload(USED_FILE)
    local used = usedData[PLACE_ID] or {}

    if #list == 0 then
        print("❌ Lista de servidores vazia")
        return nil
    end

    -- Ordena por players (menor para maior)
    table.sort(list, function(a, b)
        return (a.players or 0) < (b.players or 0)
    end)

    for _, server in ipairs(list) do
        local id = server.jobId
        if id ~= game.JobId and not isUsed(id, used) then
            return server
        end
    end

    -- Se todos foram usados, limpa a lista
    print("🔄 Todos os servidores foram usados, limpando lista...")
    usedData[PLACE_ID] = {}
    jsave(USED_FILE, usedData)

    -- Tenta novamente
    for _, server in ipairs(list) do
        local id = server.jobId
        if id ~= game.JobId then
            return server
        end
    end

    return nil
end

-- SISTEMA DE TELEPORTE UNIVERSAL (funciona em QUALQUER jogo)
local function teleportToServer(server)
    if not server or not server.jobId then
        print("❌ Servidor inválido")
        return false
    end

    local serverId = server.jobId
    local player = Players.LocalPlayer
    
    print("🚀 Teleportando para:", serverId, "(" .. (server.players or "?") .. " jogadores)")
    markTarget(serverId)
    markUsed(serverId)

    -- ========== MÉTODO 1: ServerBrowser (Blox Fruits e jogos específicos) ==========
    print("📡 Método 1: ServerBrowser...")
    local serverBrowser = ReplicatedStorage:FindFirstChild("__ServerBrowser")
    if serverBrowser then
        local success, err = pcall(function()
            serverBrowser:InvokeServer("teleport", serverId)
        end)
        if success then
            print("✅ Teleporte iniciado (ServerBrowser)")
            return true
        else
            print("❌ ServerBrowser falhou:", tostring(err))
        end
    else
        print("⚠️ ServerBrowser não disponível")
    end

    -- ========== MÉTODO 2: TeleportService padrão ==========
    print("📡 Método 2: TeleportService...")
    local success2, err2 = pcall(function()
        TeleportService:TeleportToPlaceInstance(tonumber(PLACE_ID), serverId, player)
    end)
    
    if success2 then
        print("✅ Teleporte iniciado (TeleportService)")
        return true
    else
        print("❌ TeleportService falhou:", tostring(err2))
        
        -- Verifica se é erro de token
        local errStr = tostring(err2):lower()
        if errStr:find("teleport token") or errStr:find("unauthorized") or errStr:find("773") then
            print("⚠️ Erro de token detectado! Aplicando correções...")
            
            -- ========== MÉTODO 3: Aguardar e tentar novamente ==========
            print("⏳ Aguardando 3 segundos para renovar token...")
            task.wait(3)
            
            print("📡 Método 3: Retry com token renovado...")
            local success3, err3 = pcall(function()
                TeleportService:TeleportToPlaceInstance(tonumber(PLACE_ID), serverId, player)
            end)
            
            if success3 then
                print("✅ Teleporte iniciado (Retry)")
                return true
            else
                print("❌ Retry falhou:", tostring(err3))
                
                -- ========== MÉTODO 4: Respawn para novo token ==========
                print("📡 Método 4: Respawn para novo token...")
                if player.Character and player.Character:FindFirstChild("Humanoid") then
                    player.Character:BreakJoints()
                    print("💀 Aguardando respawn...")
                    task.wait(3)
                    
                    -- Espera personagem carregar
                    local waited = 0
                    repeat
                        task.wait(1)
                        waited = waited + 1
                    until (player.Character and player.Character:FindFirstChild("Humanoid") and player.Character.Humanoid.Health > 0) or waited > 10
                    
                    if waited <= 10 then
                        task.wait(1)
                        local success4, err4 = pcall(function()
                            TeleportService:TeleportToPlaceInstance(tonumber(PLACE_ID), serverId, player)
                        end)
                        
                        if success4 then
                            print("✅ Teleporte iniciado (Respawn)")
                            return true
                        else
                            print("❌ Respawn falhou:", tostring(err4))
                        end
                    else
                        print("⚠️ Timeout no respawn")
                    end
                end
            end
        end
    end

    print("💥 Todos os métodos falharam!")
    removeUsed(serverId)
    return false
end

-- Verifica se precisa trocar de servidor
local function checkNeedHop()
    local accounts = loadAccounts()
    local playersHere = Players:GetPlayers()
    local myAccountsHere = {}

    -- Verifica contas no mesmo servidor
    for _, plr in ipairs(playersHere) do
        if accounts[plr.Name] then
            table.insert(myAccountsHere, plr.Name)
        end
    end

    -- Verifica limite de jogadores
    if #playersHere > 12 then
        print("⚠️ Servidor tem " .. #playersHere .. " jogadores! (Limite é 12)")
        return true
    end

    -- Verifica contas duplicadas
    if #myAccountsHere >= 2 then
        table.sort(myAccountsHere)
        local keeper = myAccountsHere[1]

        if PLAYER_NAME ~= keeper then
            print("⚠️ Outra conta minha detectada (" .. keeper .. "), vou trocar...")
            return true
        else
            print("✅ Sou a conta que vai ficar (" .. PLAYER_NAME .. ")")
            return false
        end
    end

    return false
end

-- Monitoramento principal
local function monitor()
    print("🤖 Iniciando monitoramento...")
    
    local failedTeleports = 0
    local maxFailedAttempts = 5
    local lastServerId = game.JobId
    local lastCheckTime = 0
    local CHECK_DELAY = 10  -- Segundos entre verificações (reduzido de 5s)

    while true do
        task.wait(CHECK_DELAY)
        
        -- Força refresh do cache a cada 5 minutos (mais conservador)
        local now = os.time()
        if (now - last_servers_fetch) >= 300 then
            servers_cache = nil  -- Invalida cache
        end

        -- Verifica se teleporte foi confirmado
        if game.JobId ~= lastServerId then
            print("✅ Teleporte confirmado! Novo servidor:", game.JobId)
            failedTeleports = 0
            lastServerId = game.JobId
        end

        -- Verifica se precisa trocar
        if checkNeedHop() then
            print("🔄 Procurando novo servidor...")

            -- Tenta até 3 servidores diferentes
            local tried = 0
            local maxTry = 3
            local success = false

            while tried < maxTry and not success do
                local server = getServer()
                if not server then
                    print("❌ Nenhum servidor disponível")
                    break
                end

                tried = tried + 1
                print("🎯 Tentativa " .. tried .. "/" .. maxTry .. ":", server.jobId)

                success = teleportToServer(server)

                if success then
                    failedTeleports = 0
                    print("⏳ Aguardando confirmação...")
                    task.wait(8)
                    break
                else
                    removeUsed(server.jobId)
                    print("🗑️ Servidor removido, tentando próximo...")
                    task.wait(3)
                end
            end

            if not success then
                failedTeleports = failedTeleports + 1
                print("❌ Falhou " .. failedTeleports .. "/" .. maxFailedAttempts .. " vezes")

                if failedTeleports >= maxFailedAttempts then
                    print("💤 Muitas falhas, aguardando 60 segundos...")
                    task.wait(60)
                    failedTeleports = 0
                else
                    task.wait(10)
                end
            end
        end
    end
end

-- Handler para falhas assíncronas
TeleportService.TeleportInitFailed:Connect(function(player, resultEnum, errorMessage, placeId, instanceId)
    if player ~= Players.LocalPlayer then return end
    print("❌ Teleporte falhou (assíncrono):", tostring(resultEnum), tostring(errorMessage))
    if instanceId then
        removeUsed(instanceId)
        print("🗑️ Removido:", instanceId)
    end
end)

-- Inicialização
print("=" .. string.rep("=", 50) .. "=")
print("🤖 SISTEMA DE HOP - GITHUB UNIVERSAL")
print("=" .. string.rep("=", 50) .. "=")
print("🎮 Place ID:", PLACE_ID)
print("👤 Player:", PLAYER_NAME)
print("🆔 Servidor:", game.JobId)
print("-" .. string.rep("-", 50) .. "-")

-- Carrega dados
local servers = loadServers()
local accounts = loadAccounts()

if servers and servers[PLACE_ID] then
    print("📊 Servidores:", #servers[PLACE_ID])
else
    print("⚠️ Sem servidores para este jogo!")
end

if accounts then
    local total = 0
    for _ in pairs(accounts) do total = total + 1 end
    print("📊 Contas:", total)
end

print("-" .. string.rep("-", 50) .. "-")

-- Anti-loop
if justHoppedHere() then
    print("⛔ Anti-loop ativo...")
    task.wait(PROTECT)
end

-- BLUE LOCK: Só corrige colisão de contas, o resto fica pro BananaHub
local BLUE_LOCK_ID = "18668065416"
if PLACE_ID == BLUE_LOCK_ID then
    print("🔵 Modo Blue Lock ativo!")
    print("   BananaHub cuida do hop da partida.")
    print("   Nosso script só evita contas duplicadas.")
    
    if checkNeedHop() then
        print("⚠️ Detectei 2+ contas minhas aqui! Fazendo hop...")
        local server = getServer()
        if server then
            teleportToServer(server)
        end
    else
        print("✅ Nenhuma conta duplicada. Ficando no servidor.")
    end
    
    print("🔵 Script finalizado no Blue Lock (BananaHub assume)")
    return  -- Não inicia o monitor
end

-- Outros jogos: Inicia monitoramento normal
print("🚀 Iniciando em 3 segundos...")
task.wait(3)
task.spawn(monitor)
print("✅ Sistema ativo!")
