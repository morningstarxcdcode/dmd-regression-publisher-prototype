module app;

import alpha : alphaScore;
import delta : deltaSummary;
import std.algorithm.searching : canFind;
import std.stdio : writeln;

ulong workspaceTotal(size_t n)
{
    ulong acc = 0;
    foreach (i; 0 .. n)
        acc += alphaScore(i) + deltaSummary(i).length;
    return acc;
}

void main()
{
    writeln(workspaceTotal(256));
}

unittest
{
    assert(workspaceTotal(8) > 0);
    assert(deltaSummary(12).canFind("delta"));
}
