module gamma;

import std.array : appender;
import std.conv : to;

int[] gammaSeries(size_t seed)
{
    auto result = appender!(int[])();
    foreach (i; 0 .. 16)
        result.put(cast(int) ((seed + i) * 7 + (i % 3)));
    return result.data;
}

string gammaText(size_t seed)
{
    auto values = gammaSeries(seed);
    return "gamma:" ~ values.length.to!string ~ ":" ~ values[$ - 1].to!string;
}

unittest
{
    assert(gammaSeries(2).length == 16);
    assert(gammaText(5).length > 0);
}
