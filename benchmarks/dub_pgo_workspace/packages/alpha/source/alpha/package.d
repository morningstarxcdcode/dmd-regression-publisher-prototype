module alpha;

import beta : betaScore;
import gamma : gammaText;

ulong alphaScore(size_t n)
{
    ulong acc = 0;
    foreach (i; 0 .. 12)
        acc += betaScore(n + i) ^ cast(ulong) gammaText(n + i).length;
    return acc;
}

unittest
{
    assert(alphaScore(4) > 0);
}
