-- Single-Player FastTravel Mod
-- Modified from original AssettoServer FastTravel plugin by Tsuka1427
-- Adapted for offline single-player use as CSP app

-- Simple config storage (ac.storage can't store tables/vec3)
local config = ac.storage({
    disableCollisions = true,
    showMapImg = true,
})

local mapFixedTargetPosition = vec3(0, 0, 0)
local mapZoomValue = { 100, 1000, 4000, 15000 }
local mapMoveSpeed = { 1, 5, 20, 0 }

local supportAPI_physics = physics.setGentleStop ~= nil
local supportAPI_collision = physics.disableCarCollisions ~= nil
local supportAPI_matrix = ac.getPatchVersionCode() >= 3037
local trackCompassOffset = 0

local font = 'Segoe UI'
local fontBold = 'Segoe UI;Weight=Bold'

local sim = ac.getSim()
local trackMapImage = ac.getFolder(ac.FolderID.ContentTracks) .. '/' .. ac.getTrackFullID('/') .. '/map.png'
ui.decodeImage(trackMapImage)
local trackMapImageSize = vec2(981, 1440)
if ui.isImageReady(trackMapImage) then
    trackMapImageSize = ui.imageSize(trackMapImage)
end

-- Initialize geometry shots with screen size
local windowSize = vec2(sim.windowWidth, sim.windowHeight)
local mapShot = ac.GeometryShot(ac.findNodes('trackRoot:yes'), windowSize, 1, false)
mapShot:setClippingPlanes(10, 30000)

local mapFullShot = ac.GeometryShot(ac.findNodes('sceneRoot:yes'), windowSize, 1, false)

local roadsNode = ac.findNodes('trackRoot:yes'):findMeshes('{ ?ROAD?, ?Road?, ?road?, ?ASPH?, ?Asph?, ?asph?, ?jnc_asp? }')
local roadsShot = ac.GeometryShot(roadsNode, windowSize, 1, false)
roadsShot:setShadersType(render.ShadersType.Simplified)
roadsShot:setAmbientColor(rgbm(100, 100, 100, 1))
roadsShot:setClippingPlanes(10, 30000)
ac.setExtraTrackLODMultiplier(10)

local roadsAABB_min, roadsAABB_max, meshCount = roadsNode:getStaticAABB()
local limitArea = vec4(roadsAABB_min.x, roadsAABB_min.z, roadsAABB_max.x, roadsAABB_max.z)

-- Auto-center map
if mapFixedTargetPosition.x == 0 and mapFixedTargetPosition.z == 0 then
    mapFixedTargetPosition = vec3((roadsAABB_min.x + roadsAABB_max.x) / 2, 0, (roadsAABB_min.z + roadsAABB_max.z) / 2)
end

-- State variables
local mapCamera = nil
local mapCameraOwn = 0
local mapMode = false
local mapZoom = 1
local mapFOV = 90
local mapMovePower = vec2()
local mapTargetPos = vec3()
local mapTargetEstimate = 0
local mouseThreshold = vec2(0.4, 0.4)
local lastPos = vec3()
local lastMp = vec2()
local lastCameraMode = 0
local disabledCollision = false
local teleportEstimate = 0
local teleportAvailable = false
local map_opacity = 0

-- Helper functions
local function posToViewSpace(mat, pos)
    local o = mat:transform(vec4(pos.x, pos.y, pos.z, 1))
    return vec2(o.x, -o.y) / o.w / 2 + 0.5
end

local function screenToWorldDir(screenPos, view, proj)
    local p1 = proj:inverse():transformPoint(vec3(2 * screenPos.x - 1, 1 - 2 * screenPos.y, 0.5))
    return view:inverse():transformVector(p1):normalize()
end

local issueIgnoreFrames = 3
local issueHeightFrame = 0
local lastRealHeight = -9999
local function getTrackDistance(pos, dir)
    local d = physics.raycastTrack(pos, dir, 10000)
    if 10000 < d or d < 0.0 then d = -1 end
    if d ~= -1 then
        issueHeightFrame = 0
        lastRealHeight = d
        return lastRealHeight
    else
        issueHeightFrame = issueHeightFrame + 1
        if issueHeightFrame < issueIgnoreFrames then
            return lastRealHeight
        end
    end
    lastRealHeight = -9999
    return nil
end

local function projectPoint(position, winSize)
    local screenPos = vec2()
    if supportAPI_matrix and mapCamera then
        local t = mapCamera.transform
        local view = mat4x4.look(t.position, t.look, t.up)
        local proj = mat4x4.perspective(math.rad(mapCamera.fov), winSize.x / winSize.y, 10, 30000)
        screenPos = posToViewSpace(view:mul(proj), position)
    else
        if ac.getPatchVersionCode() >= 2735 then
            screenPos = render.projectPoint(position, render.ProjectFace.Center)
        else
            screenPos = render.projectPoint(position)
        end
    end
    return screenPos
end

function teleportExec(pos, rot)
    if supportAPI_physics then physics.setGentleStop(0, false) end
    physics.setCarPosition(0, pos, rot)
    ac.log(string.format('Teleported to: %.1f, %.1f, %.1f', pos.x, pos.y, pos.z))
    mapMode = false
end

function inputCheck(winSize)
    local carState = ac.getCar(0)
    if ui.keyboardButtonPressed(ui.KeyIndex.M, false) and not ui.anyItemFocused() and not ui.anyItemActive() and not sim.isPaused then
        mapMode = not mapMode
        if mapMode then
            if not mapCamera then
                mapCamera = ac.grabCamera('map camera')
            end
            mapZoom = 1
            lastPos = carState.position:clone()
            lastMp = ui.mousePos()
            mapCamera.transform.position = lastPos
            mapCamera.fov = mapFOV
            lastCameraMode = sim.cameraMode
            ac.log('FastTravel map opened')
        else
            ac.log('FastTravel map closed')
        end
    end

    if mapMode and mapCamera then
        if sim.isPaused then
            mapMode = false
            return
        end

        local mp = ui.mouseLocalPos()
        local mw = ui.mouseWheel()

        local pos, dir
        if supportAPI_matrix then
            local view = mat4x4.look(mapCamera.transform.position, mapCamera.transform.look, mapCamera.transform.up)
            local proj = mat4x4.perspective(math.rad(mapCamera.fov), winSize.x / winSize.y, 10, 30000)
            pos = mapCamera.transform.position
            dir = screenToWorldDir(mp / winSize, view, proj)
        else
            local ray = render.createPointRay(mp)
            pos = ray.pos
            dir = ray.dir
        end

        local mpr = nil
        local distance = getTrackDistance(pos, dir)
        if distance then
            mpr = pos + dir * distance
        end

        -- Zoom handling
        local zoomed = false
        local lastMapZoom = mapZoom
        if mw < 0 and mapZoom < #mapZoomValue then
            mapZoom = mapZoom + 1
            zoomed = true
        elseif mw > 0 and mapZoom > 1 then
            mapZoom = mapZoom - 1
            zoomed = true
        end
        if zoomed then
            mapTargetEstimate = 0
            if mapZoom == #mapZoomValue then
                mapTargetPos = mapFixedTargetPosition
            elseif mpr ~= nil then
                mapTargetPos = mpr
            else
                mapTargetPos = pos + dir * mapZoomValue[lastMapZoom]
            end
        end

        -- Edge panning
        mapMovePower = vec2()
        if mapZoom < #mapZoomValue and lastMp:distance(mp) > 10 then
            lastMp = vec2(-1, -1)
            if mp.x > winSize.x * (1 - mouseThreshold.x) and limitArea.z > mapCamera.transform.position.x then
                mapMovePower.x = (mp.x - (winSize.x * (1 - mouseThreshold.x)))
            elseif mp.x < winSize.x * mouseThreshold.x and limitArea.x < mapCamera.transform.position.x then
                mapMovePower.x = -((winSize.x * mouseThreshold.x) - mp.x)
            end
            if mp.y > winSize.y * (1 - mouseThreshold.y) and limitArea.w > mapCamera.transform.position.z then
                mapMovePower.y = (mp.y - (winSize.y * (1 - mouseThreshold.y)))
            elseif mp.y < winSize.y * mouseThreshold.y and limitArea.y < mapCamera.transform.position.z then
                mapMovePower.y = -((winSize.y * mouseThreshold.y) - mp.y)
            end
        end
        mapMovePower = mapMovePower * sim.dt

        -- Teleport on click
        local pos = vec3()
        local rot = nil
        teleportAvailable = false
        if mpr ~= nil then
            teleportAvailable = true
            pos = mpr
        end
        if teleportAvailable then
            if ui.mouseClicked(ui.MouseButton.Left) then
                mapTargetPos = pos
                mapTargetEstimate = 0
                mapMovePower = vec2()
                teleportExec(pos, rot)
            end
        end
    end
end

-- Window initialization
local geometryShotsRebuilt = false
local lastWindowSize = vec2(800, 600)
local windowSizeCheckInterval = 0
local targetWindowSize = vec2(sim.windowWidth, sim.windowHeight)

function script.onShowWindow()
    -- Try different window name patterns
    local patterns = {
        'IMGUI_LUA_FastTravel_fasttravel_main',
        'IMGUI_LUA_fasttravel_app_fasttravel_main',
        'fasttravel_main'
    }

    targetWindowSize = vec2(sim.windowWidth, sim.windowHeight)

    for _, pattern in ipairs(patterns) do
        local appWindow = ac.accessAppWindow(pattern)
        if appWindow then
            appWindow:move(vec2(0, 0))
            appWindow:setSize(targetWindowSize)
            ac.log('FastTravel: Found window "' .. pattern .. '", moved to 0,0 and sized to ' .. targetWindowSize.x .. 'x' .. targetWindowSize.y)
            return
        end
    end
    ac.log('FastTravel: Could not find window to reposition')
end

-- Main window function
function script.windowMain(dt)
    local winSize = ui.windowSize()

    -- Check if game window size changed
    local currentScreenSize = vec2(sim.windowWidth, sim.windowHeight)
    if math.abs(targetWindowSize.x - currentScreenSize.x) > 10 or math.abs(targetWindowSize.y - currentScreenSize.y) > 10 then
        targetWindowSize = currentScreenSize
        windowSizeCheckInterval = 0  -- Force immediate check
    end

    -- Periodically try to resize window to match screen if it's not the right size
    windowSizeCheckInterval = windowSizeCheckInterval + dt
    if windowSizeCheckInterval > 1 then  -- Check every second
        windowSizeCheckInterval = 0
        if math.abs(winSize.x - targetWindowSize.x) > 10 or math.abs(winSize.y - targetWindowSize.y) > 10 then
            local patterns = {
                'IMGUI_LUA_FastTravel_fasttravel_main',
                'IMGUI_LUA_fasttravel_app_fasttravel_main',
                'fasttravel_main'
            }
            for _, pattern in ipairs(patterns) do
                local appWindow = ac.accessAppWindow(pattern)
                if appWindow then
                    appWindow:move(vec2(0, 0))
                    appWindow:setSize(targetWindowSize)
                    ac.log('FastTravel: Resized window to ' .. targetWindowSize.x .. 'x' .. targetWindowSize.y)
                    break
                end
            end
        end
    end

    -- Rebuild geometry shots if window size changed significantly
    if not geometryShotsRebuilt or math.abs(winSize.x - lastWindowSize.x) > 50 or math.abs(winSize.y - lastWindowSize.y) > 50 then
        windowSize = vec2(winSize.x, winSize.y)
        lastWindowSize = winSize:clone()

        mapShot = ac.GeometryShot(ac.findNodes('trackRoot:yes'), windowSize, 1, false)
        mapShot:setClippingPlanes(10, 30000)
        mapFullShot = ac.GeometryShot(ac.findNodes('sceneRoot:yes'), windowSize, 1, false)
        roadsShot = ac.GeometryShot(roadsNode, windowSize, 1, false)
        roadsShot:setShadersType(render.ShadersType.Simplified)
        roadsShot:setAmbientColor(rgbm(100, 100, 100, 1))
        roadsShot:setClippingPlanes(10, 30000)

        geometryShotsRebuilt = true
        ac.log('FastTravel: Adapted to window size ' .. winSize.x .. 'x' .. winSize.y)
    end

    -- Setup window drawing
    ui.pushClipRect(vec2(0, 0), winSize)
    ui.invisibleButton('ftBackground', winSize)

    -- Update logic
    teleportEstimate = teleportEstimate + dt
    mapTargetEstimate = mapTargetEstimate + dt
    inputCheck(winSize)

    mapCameraOwn = math.applyLag(mapCameraOwn, mapMode and 1 or 0, mapMode and 0.9 or 0.8, dt)
    if mapCamera then
        if mapCameraOwn < 0.001 then
            mapCamera.ownShare = 0
            mapCamera:dispose()
            mapCamera = nil
        else
            mapCamera.ownShare = mapCameraOwn
        end
    end

    if mapMode then
        if supportAPI_physics then physics.setGentleStop(0, true) end
        if config.disableCollisions and not disabledCollision then
            if supportAPI_collision then
                physics.disableCarCollisions(0, true)
            end
            disabledCollision = true
        end
        teleportEstimate = 0
    elseif mapCamera and mapCamera.ownShare > 0 then
        ac.setCurrentCamera(lastCameraMode)
        ac.focusCar(0)
    end

    if teleportEstimate > 1 then
        if supportAPI_physics then physics.setGentleStop(0, false) end
    end

    if config.disableCollisions and disabledCollision and teleportEstimate > 5 then
        local closer = false
        for i = 1, sim.carsCount - 1 do
            local carState = ac.getCar(i)
            local dist = carState.position:distance(ac.getCar(0).position)
            if dist < (carState.aabbSize.z / 2) then
                closer = true
                teleportEstimate = teleportEstimate - 1
                break
            end
        end
        if not closer and disabledCollision then
            if supportAPI_collision then
                physics.disableCarCollisions(0, false)
            end
            disabledCollision = false
        end
    end

    -- Draw UI
    if mapMode then
        if mapCamera then
            -- Update camera position
            mapCamera.transform.position.y = math.applyLag(mapCamera.transform.position.y, lastPos.y + mapZoomValue[mapZoom], 0.8, dt)
            if mapTargetEstimate < 0.3 then
                mapCamera.transform.position.x = math.applyLag(mapCamera.transform.position.x, math.max(limitArea.x, math.min(limitArea.z, mapTargetPos.x)), 0.8, dt)
                mapCamera.transform.position.z = math.applyLag(mapCamera.transform.position.z, math.max(limitArea.y, math.min(limitArea.w, mapTargetPos.z)), 0.8, dt)
            end
            mapCamera.transform.position.x = mapCamera.transform.position.x + (mapMovePower.x * mapMoveSpeed[mapZoom])
            mapCamera.transform.position.z = mapCamera.transform.position.z + (mapMovePower.y * mapMoveSpeed[mapZoom])
            mapCamera.transform.look = vec3(0, -1, 0)
            mapCamera.transform.up = vec3(0, 0, -1)

            -- Update geometry shots
            if mapZoom == 1 then
                mapFullShot:update(mapCamera.transform.position, mapCamera.transform.look, mapCamera.transform.up, mapFOV)
            else
                mapShot:update(mapCamera.transform.position, mapCamera.transform.look, mapCamera.transform.up, mapFOV)
            end
            roadsShot:update(mapCamera.transform.position, mapCamera.transform.look, mapCamera.transform.up, mapFOV)
        end

        -- Draw map
        local mp = ui.mouseLocalPos()
        mapShot:setShadersType(render.ShadersType.Simplest)
        mapFullShot:setShadersType(render.ShadersType.Simplest)
        ui.drawRectFilled(vec2(), winSize, rgbm(0, 0, 0, 0.5))

        if mapZoom == 1 then
            ui.drawImage(mapFullShot, vec2(), winSize)
        else
            ui.drawImage(mapShot, vec2(), winSize)
        end
        ui.drawImage(roadsShot, vec2(), winSize, rgbm(0, 0.9, 1, 1))

        -- Draw cursor
        local cursorSize = 15
        if teleportAvailable then
            ui.drawCircle(mp, cursorSize, rgbm(0, 1, 0, 1), 16, 2)
        else
            ui.drawCircle(mp, cursorSize, rgbm(1, 0, 0, 1), 16, 2)
        end

        -- Draw help text
        ui.dwriteDrawText('Left Click: Teleport | Mouse Wheel: Zoom | M: Close', 18, vec2(10, winSize.y - 30), rgbm(1, 1, 1, 1))
    else
        -- Show hint when not in map mode and stationary
        local carState = ac.getCar(0)
        if carState.speedKmh < 2 then
            local opacity = math.sin(sim.gameTime * 5) / 2 + 0.5
            ui.pushDWriteFont(fontBold)
            ui.dwriteDrawText('Press M key to FastTravel', 20, vec2(winSize.x * 0.1, winSize.y * 0.9), rgbm(1, 1, 1, opacity))
            ui.popDWriteFont()
        end
    end

    ui.popClipRect()
end
