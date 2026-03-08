module delta;

import gamma : gammaSeries, gammaText;
import std.algorithm : sum;
import std.conv : to;

string deltaSummary(size_t seed)
{
    auto series = gammaSeries(seed);
    auto total = series.sum;
    return "delta:" ~ seed.to!string ~ ":" ~ total.to!string ~ ":" ~ gammaText(seed);
}

unittest
{
    assert(deltaSummary(9).length > 0);
}
