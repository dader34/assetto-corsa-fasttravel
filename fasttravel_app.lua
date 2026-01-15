-- Single-Player FastTravel Mod
-- Modified from original AssettoServer FastTravel plugin by Tsuka1427
-- Adapted for offline single-player use as CSP app

-- Constants
local CLIP_NEAR = 10
local CLIP_FAR = 30000
local RAYCAST_MAX_DIST = 10000
local CAMERA_LAG = 0.8
local CAMERA_FADE_THRESHOLD = 0.001
local TARGET_SMOOTHING_TIME = 0.3
local GENTLE_STOP_DELAY = 1
local COLLISION_REENABLE_DELAY = 5
local SCREEN_RESIZE_THRESHOLD = 50
local MOUSE_MOVE_THRESHOLD = 10
local INVALID_HEIGHT = -9999
local HEIGHT_IGNORE_FRAMES = 3

local ZOOM_HEIGHTS = { 100, 1000, 4000, 15000 }
local PAN_SPEEDS = { 1, 5, 20, 0 }
local EDGE_THRESHOLD = 0.4

-- Config (persisted)
local config = ac.storage({
    disableCollisions = true,
})

-- CSP API availability
local supportAPI_physics = physics.setGentleStop ~= nil
local supportAPI_collision = physics.disableCarCollisions ~= nil
local supportAPI_matrix = ac.getPatchVersionCode() >= 3037

local sim = ac.getSim()

-- Track bounds for camera limits
local trackBounds = { xMin = 0, xMax = 0, zMin = 0, zMax = 0 }
local mapCenterPos = vec3(0, 0, 0)

local roadsNode = ac.findNodes('trackRoot:yes'):findMeshes('{ ?ROAD?, ?Road?, ?road?, ?ASPH?, ?Asph?, ?asph?, ?jnc_asp? }')
local roadsAABB_min, roadsAABB_max = roadsNode:getStaticAABB()
if roadsAABB_min and roadsAABB_max then
    trackBounds.xMin = roadsAABB_min.x
    trackBounds.xMax = roadsAABB_max.x
    trackBounds.zMin = roadsAABB_min.z
    trackBounds.zMax = roadsAABB_max.z
    mapCenterPos = vec3((roadsAABB_min.x + roadsAABB_max.x) / 2, 0, (roadsAABB_min.z + roadsAABB_max.z) / 2)
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
local carStartPos = vec3()
local lastMousePos = vec2()
local lastCameraMode = 0
local disabledCollision = false
local teleportEstimate = 0

-- Height tracking for raycast smoothing
local heightIgnoreCount = 0
local lastValidHeight = INVALID_HEIGHT

-- Helper: Convert screen position to world direction
local function screenToWorldDir(screenPos, view, proj)
    local p1 = proj:inverse():transformPoint(vec3(2 * screenPos.x - 1, 1 - 2 * screenPos.y, 0.5))
    return view:inverse():transformVector(p1):normalize()
end

-- Helper: Raycast to track with frame smoothing to handle gaps
local function getTrackDistance(pos, dir)
    local dist = physics.raycastTrack(pos, dir, RAYCAST_MAX_DIST)

    if dist >= 0 and dist < RAYCAST_MAX_DIST then
        heightIgnoreCount = 0
        lastValidHeight = dist
        return dist
    end

    -- Use last valid height for a few frames to smooth over gaps
    heightIgnoreCount = heightIgnoreCount + 1
    if heightIgnoreCount < HEIGHT_IGNORE_FRAMES then
        return lastValidHeight
    end

    lastValidHeight = INVALID_HEIGHT
    return nil
end

-- Helper: Teleport car to position
local function teleport(pos)
    if supportAPI_physics then physics.setGentleStop(0, false) end
    physics.setCarPosition(0, pos, nil)
    ac.log(string.format('Teleported to: %.1f, %.1f, %.1f', pos.x, pos.y, pos.z))
    mapMode = false
end

-- Helper: Get mouse ray origin and direction
local function getMouseRay(screenSize)
    local mousePos = ui.mousePos()

    if supportAPI_matrix then
        local camPos = mapCamera.transform.position
        local view = mat4x4.look(camPos, mapCamera.transform.look, mapCamera.transform.up)
        local proj = mat4x4.perspective(math.rad(mapCamera.fov), screenSize.x / screenSize.y, CLIP_NEAR, CLIP_FAR)
        local dir = screenToWorldDir(mousePos / screenSize, view, proj)
        return camPos, dir, mousePos
    else
        local ray = render.createPointRay(mousePos)
        return ray.pos, ray.dir, mousePos
    end
end

-- Helper: Get world position under mouse cursor
local function getMouseWorldPos(screenSize)
    local rayPos, rayDir = getMouseRay(screenSize)
    local distance = getTrackDistance(rayPos, rayDir)
    if distance then
        return rayPos + rayDir * distance
    end
    return nil
end

-- Handle map toggle with M key
local function handleMapToggle()
    local canToggle = not ui.anyItemFocused() and not ui.anyItemActive() and not sim.isPaused
    if not ui.keyboardButtonPressed(ui.KeyIndex.M, false) or not canToggle then
        return
    end

    mapMode = not mapMode
    if mapMode then
        if not mapCamera then
            mapCamera = ac.grabCamera('map camera')
        end
        mapZoom = 1
        carStartPos = ac.getCar(0).position:clone()
        lastMousePos = ui.mousePos()
        mapCamera.transform.position = carStartPos
        mapCamera.fov = mapFOV
        lastCameraMode = sim.cameraMode
        ac.log('FastTravel map opened')
    else
        ac.log('FastTravel map closed')
    end
end

-- Handle mouse wheel zoom
local function handleZoom(screenSize)
    local wheel = ui.mouseWheel()
    if wheel == 0 then return end

    local prevZoom = mapZoom
    if wheel < 0 and mapZoom < #ZOOM_HEIGHTS then
        mapZoom = mapZoom + 1
    elseif wheel > 0 and mapZoom > 1 then
        mapZoom = mapZoom - 1
    end

    if mapZoom ~= prevZoom then
        mapTargetEstimate = 0
        if mapZoom == #ZOOM_HEIGHTS then
            mapTargetPos = mapCenterPos
        else
            local worldPos = getMouseWorldPos(screenSize)
            if worldPos then
                mapTargetPos = worldPos
            else
                local rayPos, rayDir = getMouseRay(screenSize)
                mapTargetPos = rayPos + rayDir * ZOOM_HEIGHTS[prevZoom]
            end
        end
    end
end

-- Handle edge panning when mouse near screen edges
local function handleEdgePan(screenSize)
    mapMovePower = vec2()

    -- Don't pan at max zoom or if mouse hasn't moved
    local mousePos = ui.mousePos()
    if mapZoom >= #ZOOM_HEIGHTS then return end
    if lastMousePos:distance(mousePos) <= MOUSE_MOVE_THRESHOLD then return end

    lastMousePos = vec2(-1, -1)
    local camX = mapCamera.transform.position.x
    local camZ = mapCamera.transform.position.z
    local edgeX = screenSize.x * EDGE_THRESHOLD
    local edgeY = screenSize.y * EDGE_THRESHOLD

    -- Horizontal panning
    if mousePos.x > screenSize.x - edgeX and camX < trackBounds.xMax then
        mapMovePower.x = mousePos.x - (screenSize.x - edgeX)
    elseif mousePos.x < edgeX and camX > trackBounds.xMin then
        mapMovePower.x = -(edgeX - mousePos.x)
    end

    -- Vertical panning (Y screen = Z world)
    if mousePos.y > screenSize.y - edgeY and camZ < trackBounds.zMax then
        mapMovePower.y = mousePos.y - (screenSize.y - edgeY)
    elseif mousePos.y < edgeY and camZ > trackBounds.zMin then
        mapMovePower.y = -(edgeY - mousePos.y)
    end

    mapMovePower = mapMovePower * sim.dt
end

-- Handle click to teleport
local function handleTeleportClick(screenSize)
    if not ui.mouseClicked(ui.MouseButton.Left) then return end

    local worldPos = getMouseWorldPos(screenSize)
    if worldPos then
        mapTargetPos = worldPos
        mapTargetEstimate = 0
        mapMovePower = vec2()
        teleport(worldPos)
    end
end

-- Process all map input
local function processInput(screenSize)
    handleMapToggle()

    if not mapMode or not mapCamera then return end

    if sim.isPaused then
        mapMode = false
        return
    end

    handleZoom(screenSize)
    handleEdgePan(screenSize)
    handleTeleportClick(screenSize)
end

-- Window state
local mapShot = nil
local lastScreenSize = vec2(0, 0)

-- Helper: Check if any AI car is too close to player
local function isAICarNearby()
    local playerPos = ac.getCar(0).position
    for i = 1, sim.carsCount - 1 do
        local aiCar = ac.getCar(i)
        local dist = aiCar.position:distance(playerPos)
        if dist < (aiCar.aabbSize.z / 2) then
            return true
        end
    end
    return false
end

-- Helper: Update collision state after teleport
local function updateCollisionState()
    if not config.disableCollisions or not disabledCollision then return end
    if teleportEstimate <= COLLISION_REENABLE_DELAY then return end

    if isAICarNearby() then
        teleportEstimate = teleportEstimate - 1
        return
    end

    if supportAPI_collision then
        physics.disableCarCollisions(0, false)
    end
    disabledCollision = false
end

-- Helper: Update camera fade in/out
local function updateCameraFade(dt)
    local targetOwn = mapMode and 1 or 0
    local fadeSpeed = mapMode and 0.9 or CAMERA_LAG
    mapCameraOwn = math.applyLag(mapCameraOwn, targetOwn, fadeSpeed, dt)

    if not mapCamera then return end

    if mapCameraOwn < CAMERA_FADE_THRESHOLD then
        mapCamera.ownShare = 0
        mapCamera:dispose()
        mapCamera = nil
    else
        mapCamera.ownShare = mapCameraOwn
    end
end

-- Helper: Clamp value to track bounds
local function clampToTrack(x, z)
    return math.max(trackBounds.xMin, math.min(trackBounds.xMax, x)),
           math.max(trackBounds.zMin, math.min(trackBounds.zMax, z))
end

-- Helper: Update camera position when map is open
local function updateMapCamera(dt)
    if not mapMode or not mapCamera then return end

    local targetY = carStartPos.y + ZOOM_HEIGHTS[mapZoom]
    mapCamera.transform.position.y = math.applyLag(mapCamera.transform.position.y, targetY, CAMERA_LAG, dt)

    -- Smooth pan to target position
    if mapTargetEstimate < TARGET_SMOOTHING_TIME then
        local clampedX, clampedZ = clampToTrack(mapTargetPos.x, mapTargetPos.z)
        mapCamera.transform.position.x = math.applyLag(mapCamera.transform.position.x, clampedX, CAMERA_LAG, dt)
        mapCamera.transform.position.z = math.applyLag(mapCamera.transform.position.z, clampedZ, CAMERA_LAG, dt)
    end

    -- Apply edge panning
    mapCamera.transform.position.x = mapCamera.transform.position.x + (mapMovePower.x * PAN_SPEEDS[mapZoom])
    mapCamera.transform.position.z = mapCamera.transform.position.z + (mapMovePower.y * PAN_SPEEDS[mapZoom])

    -- Camera looks straight down
    mapCamera.transform.look = vec3(0, -1, 0)
    mapCamera.transform.up = vec3(0, 0, -1)

    mapShot:update(mapCamera.transform.position, mapCamera.transform.look, mapCamera.transform.up, mapFOV)
end

-- Main window function
function script.windowMain(dt)
    local screenSize = vec2(sim.windowWidth, sim.windowHeight)

    -- Rebuild geometry shot if screen size changed significantly
    if math.abs(screenSize.x - lastScreenSize.x) > SCREEN_RESIZE_THRESHOLD or
       math.abs(screenSize.y - lastScreenSize.y) > SCREEN_RESIZE_THRESHOLD then
        lastScreenSize = screenSize:clone()
        mapShot = ac.GeometryShot(ac.findNodes('trackRoot:yes'), screenSize, 1, false)
        mapShot:setClippingPlanes(CLIP_NEAR, CLIP_FAR)
        ac.log('FastTravel: Adapted to screen size ' .. screenSize.x .. 'x' .. screenSize.y)
    end

    ui.pushClipRect(vec2(0, 0), screenSize)
    ui.invisibleButton('ftBackground', screenSize)

    -- Update timers
    teleportEstimate = teleportEstimate + dt
    mapTargetEstimate = mapTargetEstimate + dt

    -- Process input
    processInput(screenSize)

    -- Update camera fade
    updateCameraFade(dt)

    -- Handle map mode state
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

    -- Release gentle stop after delay
    if teleportEstimate > GENTLE_STOP_DELAY then
        if supportAPI_physics then physics.setGentleStop(0, false) end
    end

    -- Re-enable collisions when safe
    updateCollisionState()

    -- Update camera position
    updateMapCamera(dt)

    ui.popClipRect()
end
