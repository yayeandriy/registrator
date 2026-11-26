-- Standalone zone entry (bundle `zone`): one op per call.
-- Input / output: `zone.dispatch`.

return function(input)
    return zone.dispatch(input)
end
