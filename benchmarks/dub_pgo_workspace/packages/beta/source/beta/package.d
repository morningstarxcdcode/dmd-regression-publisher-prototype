module beta;

import gamma : gammaSeries;

ulong betaScore(size_t n)
{
    ulong acc = 0;
    foreach (value; gammaSeries(n))
        acc += cast(ulong) value * 13UL + 7UL;
    return acc;
}

unittest
{
    assert(betaScore(3) > 0);
}
