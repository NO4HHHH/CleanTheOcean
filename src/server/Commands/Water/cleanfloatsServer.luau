return function(_Context)
    local Folder = workspace:FindFirstChild("Floats")
    if Folder == nil then
        return "No floats to clean"
    end
    local Count = #Folder:GetChildren()
    Folder:Destroy()
    return `Destroyed {Count} float(s)`
end
