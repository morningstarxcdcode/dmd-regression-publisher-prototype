module benchmark;

import std.algorithm : filter, map;
import std.array : array;
import std.conv : to;
import std.range : iota;
import std.stdio : writeln;
import std.string : split;

template Pow2(int N)
{
    static if (N == 0)
    {
        enum Pow2 = 1;
    }
    else
    {
        enum Pow2 = 2 * Pow2!(N - 1);
    }
}

long weighted(long value, int factor)
{
    return value * factor + (value % (factor + 1));
}

string buildDataset(size_t rowCount, size_t width)
{
    string result;
    foreach (r; 0 .. rowCount)
    {
        foreach (c; 0 .. width)
        {
            result ~= ((r * 13 + c * 17 + 11) % 997).to!string;
            if (c + 1 < width)
            {
                result ~= ":";
            }
        }
        result ~= "\n";
    }
    return result;
}

enum dataset = buildDataset(720, 12);

long datasetChecksum()
{
    long acc = 1469598103934665603L;
    foreach (ch; dataset)
    {
        acc ^= cast(ubyte) ch;
        acc *= 1099511628211L;
    }
    return acc;
}

enum checksum = datasetChecksum();

auto pipeline(R)(R values)
{
    return values
        .map!(v => weighted(v, cast(int) (v % 7 + 2)))
        .filter!(v => (v & 1) == 0)
        .array;
}

long parseAndAggregate(string input)
{
    long total = 0;
    foreach (line; input.split('\n'))
    {
        if (line.length == 0)
        {
            continue;
        }

        foreach (col; line.split(':'))
        {
            total += col.to!long;
        }
    }
    return total;
}

void instantiatePipelines()
{
    auto ints = iota(1, 6_000).array;
    auto longs = iota(2L, 6_500L).array;
    auto floats = iota(1.0, 4_000.0).array;

    auto a = pipeline(ints);
    auto b = pipeline(longs);
    auto c = pipeline(floats.map!(x => cast(long) x).array);

    assert(a.length + b.length + c.length > 0);
}

void main()
{
    instantiatePipelines();

    auto values = iota(1, 8_000).array;
    auto reduced = pipeline(values);
    auto aggregate = parseAndAggregate(dataset);
    enum compileBias = Pow2!9 + checksum % 1024;

    writeln("rows=", reduced.length, " aggregate=", aggregate + compileBias);
}
