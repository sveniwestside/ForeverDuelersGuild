return function(FD, equal)
    assert(loadfile("ForeverDuel/Profile.lua"))("ForeverDuel", FD)
    local profile = FD.Profile
    local function textRegion()
        return {
            SetText = function(self, value) self.text = value end,
            Show = function(self) self.shown = true end,
            Hide = function(self) self.shown = false end,
        }
    end
    profile.chart = {}
    for _, field in ipairs({ "chartSummary", "chartHigh", "chartLow", "chartFirst", "chartLast", "chartEmpty" }) do
        profile[field] = textRegion()
    end
    profile.chartLines = {}
    for index = 1, 40 do
        local line = textRegion()
        function line:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
        function line:SetStartPoint(point, relativeTo, x, y)
            self.start = { point = point, relativeTo = relativeTo, x = x, y = y }
        end
        function line:SetEndPoint(point, relativeTo, x, y)
            self.finish = { point = point, relativeTo = relativeTo, x = x, y = y }
        end
        profile.chartLines[index] = line
    end
    local function series(ratings)
        local result = { bracket = "LEVELING", total = #ratings - 1, shown = #ratings - 1 }
        for index, rating in ipairs(ratings) do
            result[index] = { rating = rating, ordinal = index - 1, baseline = index == 1 }
        end
        return result
    end
    local function verifyBounds(count)
        for index = 1, count do
            local line = profile.chartLines[index]
            equal(line.shown, true, "each visible match has a rendered chart segment")
            for _, anchor in ipairs({ line.start, line.finish }) do
                equal(anchor.point, "TOPLEFT", "chart uses a consistent coordinate origin")
                equal(anchor.relativeTo, profile.chart, "native line signature includes its explicit chart parent")
                equal(type(anchor.x) == "number" and anchor.x >= 68 and anchor.x <= 896, true,
                    "chart endpoint stays inside horizontal plotting bounds")
                equal(type(anchor.y) == "number" and anchor.y >= -98 and anchor.y <= -36, true,
                    "chart endpoint stays inside vertical plotting bounds without nonfinite coordinates")
            end
            if index > 1 then
                equal(line.start.x, profile.chartLines[index - 1].finish.x, "adjacent rendered matches meet horizontally")
                equal(line.start.y, profile.chartLines[index - 1].finish.y, "adjacent rendered matches meet vertically")
            end
        end
        for index = count + 1, #profile.chartLines do
            equal(profile.chartLines[index].shown, false, "unused chart segments are hidden")
        end
    end

    profile:RenderChart(series({ 1500, 1516, 1496, 1496, 1800 }))
    verifyBounds(4)
    equal(profile.chartLines[1].start.x, 68, "baseline begins at the left plot edge")
    equal(profile.chartLines[4].finish.x, 896, "latest match reaches the right plot edge")
    equal(profile.chartLines[1].finish.y > profile.chartLines[1].start.y, true, "rating gains rise on the chart")
    equal(profile.chartLines[2].finish.y < profile.chartLines[2].start.y, true, "rating losses fall on the chart")
    equal(profile.chartLines[3].finish.y, profile.chartLines[3].start.y, "zero transfer produces a flat segment")
    equal(profile.chartLines[1].color[2], 0.85, "gain segment uses the victory color")
    equal(profile.chartLines[2].color[1], 0.96, "loss segment uses the defeat color")
    equal(profile.chartLines[3].color[1], 0.94, "flat segment uses the neutral gold color")
    equal(profile.chartEmpty.shown, false, "real history clears the empty-state overlay")

    -- Switching from a busy pool to a shorter pool cannot leave stale lines.
    local shorter = series({ 1500, 1484 })
    shorter.bracket = "MAX_LEVEL"
    profile:RenderChart(shorter)
    verifyBounds(1)
    equal(profile.chartSeries.bracket, "MAX_LEVEL", "rendered data follows the newly selected pool")
    equal(profile.chartSummary.text:find("1500 -> 1484 (-16)", 1, true) ~= nil, true,
        "summary describes the visible pool's actual rating movement")

    profile:RenderChart(series({ 1500, 1500 }))
    verifyBounds(1)
    equal(profile.chartLines[1].finish.y, profile.chartLines[1].start.y,
        "entirely flat history stays finite and visible")
    profile:RenderChart(series({ 1500 }))
    verifyBounds(0)
    equal(profile.chartEmpty.shown, true, "empty pool shows its own empty-state message")
    equal(profile.chartFirst.text, "", "empty pool clears the previous first-match label")
    equal(profile.chartLast.text, "", "empty pool clears the previous last-match label")
    equal(profile.chartSummary.text, "Starting rating: 1500", "empty pool does not retain a previous gain or loss")
end
