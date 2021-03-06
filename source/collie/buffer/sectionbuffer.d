/*
 * Collie - An asynchronous event-driven network framework using Dlang development
 *
 * Copyright (C) 2015-2016  Shanghai Putao Technology Co., Ltd 
 *
 * Developer: putao's Dlang team
 *
 * Licensed under the Apache-2.0 License.
 *
 */
module collie.buffer.sectionbuffer;

//import core.stdc.string;
import core.memory;
import core.stdc.string;
import std.array;

import std.algorithm : swap;
import std.experimental.allocator;
import std.experimental.allocator.gc_allocator;
import std.experimental.logger;

import collie.buffer.buffer;
import collie.utils.vector;

/** 
 * 分段buffer，把整块的很大大内存分成多快小内存存放在内存中，防止一次申请过大内存导致的问题，理论可以无限写入，会自己增加内存。
 * 
 * 
 * 注意：内部管理内存周期的，但是支持swap交换出所管理的内存，注意分配其不同，swap出的内存的管理
 */

final class SectionBuffer : Buffer
{
    alias BufferVector = Vector!(ubyte[], false, GCAllocator); //Mallocator);

    this(size_t sectionSize, IAllocator clloc = _processAllocator)
    {
        _alloc = clloc;
        _sectionSize = sectionSize;
    }

    ~this()
    {
        clear();
    }

    void reserve(size_t size)
    {
        assert(size > 0);
        size_t sec_size = size / _sectionSize;
        if (sec_size < _buffer.length)
        {
            for (size_t i = sec_size; i < _buffer.length; ++i)
            {
                if (_buffer[i]!is null)
                {
                    _alloc.deallocate(_buffer[i]);
                    _buffer[i] = null;
                }
            }
            _buffer.removeBack(_buffer.length - sec_size);
        }
        else if (_buffer.length < sec_size)
        {
            size_t a_size = sec_size - _buffer.length;
            for (size_t i = 0; i < a_size; ++i)
            {
                _buffer.insertBack(cast(ubyte[]) _alloc.allocate(_sectionSize)); //new ubyte[_sectionSize]);//
            }
        }
        size_t lsize = size - (_buffer.length * _sectionSize);
        _buffer.insertBack(cast(ubyte[]) _alloc.allocate(lsize)); //new ubyte[lsize]);
        _rSize = 0;
        _wSize = 0;
    }

    size_t maxSize()
    {
        if (_buffer.empty())
            return size_t.max;
        size_t leng = _buffer[_buffer.length - 1].length;
        if (leng == _sectionSize)
            return size_t.max;
        else
        {
            return (_buffer.length - 1) * _sectionSize + leng;
        }
    }

    
    @property void clear()
    {
        for (size_t i = 0; i < _buffer.length; ++i)
        {
            _alloc.deallocate(_buffer[i]);
            _buffer[i] = null;
        }
        _buffer.clear();
        
        _rSize = 0;
        _wSize = 0;

		//trace("\n\tclear()!!! \n");
    }

    pragma(inline)
    @property void clearWithOutMemory()
    {
        if (maxSize() != size_t.max)
        {
            _alloc.deallocate(_buffer[_buffer.length - 1]);
            _buffer.removeBack();
        }
        _rSize = 0;
        _wSize = 0;
    }

    pragma(inline)
    size_t swap(ref BufferVector uarray)
    {
        auto size = _wSize;
        .swap(uarray, _buffer);
        _rSize = 0;
        _wSize = 0;
        return size;
    }

    override @property bool eof() const
    {
        return isEof;
    }

    override void rest(size_t size = 0)
    {
        _rSize = size;
    }

    override @property size_t length() const
    {
        return _wSize;
    }

    pragma(inline,true)
    @property size_t stectionSize()
    {
        return _sectionSize;
    }

    pragma(inline)
    size_t read(ubyte[] data)
    {
        size_t rlen = 0;
        return read(data.length, delegate(in ubyte[] dt) {
            auto len = rlen;
            rlen += dt.length;
            data[len .. rlen] = dt[];

        });

    }

    override size_t read(size_t size, void delegate(in ubyte[]) cback) //回调模式，数据不copy
    {
        size_t len = _wSize - _rSize;
        size_t maxlen = size < len ? size : len;
        size_t rcount = readCount();
        size_t rsite = readSite();
        size_t rlen = 0, tlen;
        while (rcount < _buffer.length)
        {
            ubyte[] by = _buffer[rcount];
            tlen = maxlen - rlen;
            len = by.length - rsite;
            if (len >= tlen)
            {
                cback(by[rsite .. (tlen + rsite)]);
                rlen += tlen;
                _rSize += tlen;
                break;
            }
            else
            {
                cback(by[rsite .. $]);
                _rSize += len;
                rlen += len;
                rsite = 0;
                ++rcount;
            }
        }
        //_rSize += maxlen;
        return maxlen;
    }

    override size_t write(in ubyte[] data)
    {
        size_t len = maxSize() - _wSize;
        size_t maxlen = data.length < len ? data.length : len;
        size_t wcount = writeCount();
        size_t wsite = writeSite();
        size_t wlen = 0, tlen;
        size_t maxSize = maxSize;
        while (_wSize < maxSize)
        {
            if (wcount == _buffer.length)
            {
                _buffer.insertBack(cast(ubyte[]) _alloc.allocate(_sectionSize)); //new ubyte[_sectionSize]);//
            }
            ubyte[] by = _buffer[wcount];
            tlen = maxlen - wlen;
            len = by.length - wsite;
            if (len >= tlen)
            {
                by[wsite .. (wsite + tlen)] = data[wlen .. (wlen + tlen)];
                break;
            }
            else
            {
                by[wsite .. (wsite + len)] = data[wlen .. (wlen + len)];
                wlen += len;
                wsite = 0;
                ++wcount;
            }
        }
        _wSize += maxlen;
        return maxlen;
    }

    pragma(inline)
    ubyte[] readLine(bool hasRN = false)() //返回的数据有copy
    {
      //  ubyte[] rbyte;
		auto rbyte = appender!(ubyte[])();
		auto len = readLine!(hasRN)(delegate(in ubyte[] data) { rbyte.put(data);/*rbyte ~= data;*/ });
        return rbyte.data;
    }

    size_t readLine(bool hasRN = false)(void delegate(in ubyte[]) cback) //回调模式，数据不copy
    {
        if (isEof())
            return 0;
        size_t rcount = readCount();
        size_t rsite = readSite();
        //bool crcf = false;
        size_t size = _rSize;
        ubyte[] rbyte;
        size_t wsite = writeSite();
        size_t wcount = writeCount();
        ubyte[] byptr, by;
        while (rcount <= wcount && !isEof())
        {
            by = _buffer[rcount];
            if (rcount == wcount)
            {
                byptr = by[rsite .. wsite];
            }
            else
            {
                byptr = by[rsite .. $];
            }
			ptrdiff_t site = findUbyte(byptr,cast(ubyte)('\n'));
            if (site == -1)
            {
                if (rbyte.length > 0)
                {
                    cback(rbyte);
                    rbyte = null;
                }
                rbyte = byptr;
                rsite = 0;
                ++rcount;
                _rSize += rbyte.length;
            }
            else if (rbyte.length > 0 && site == 0)
            {
                ++_rSize;
                static if (!hasRN)
                {
                    auto len = rbyte.length - 1;
                    if (rbyte[len] == '\r')
                    {
                        if (len == 0)
                        {
                            _rSize += _rSize;
                            return _rSize - size;
                        }
                        rbyte = rbyte[0 .. len];
                    }
                }
                cback(rbyte);
                static if (hasRN)
                {
                    cback(byptr[0 .. 1]);
                }
                rbyte = null;
                break;
            }
            else
            {
                ++_rSize;
                if (site == 0)
                {
                    static if (hasRN)
                    {
                        cback(byptr[0 .. 1]);
                    }
                    return _rSize - size;
                }
                cback(rbyte);
                rbyte = null;
                rbyte = byptr[0 .. (site + 1)];
                _rSize += site; //rbyte.length;
                static if (!hasRN)
                {
                    auto len = rbyte.length - 2;
                    if (rbyte[len] == '\r')
                    {
                        if (len == 0)
                            return _rSize - size;
                        rbyte = rbyte[0 .. len];
                    }
                }
                cback(rbyte);
                rbyte = null;
                break;
            }
        }

        if (rbyte.length > 0)
        {
            cback(rbyte);
        }
        return _rSize - size;
    }

    size_t readAll(void delegate(in ubyte[]) cback) //回调模式，数据不copy
    {
        size_t maxlen = _wSize - _rSize;
        size_t rcount = readCount();
        size_t rsite = readSite();
        size_t wcount = writeCount();
        size_t wsize = writeSite();
        ubyte[] rbyte;
        while (rcount <= wcount && !isEof())
        {
            ubyte[] by = _buffer[rcount];
            if (rcount == wcount)
            {
                rbyte = by[rsite .. wsize];
            }
            else
            {
                rbyte = by[rsite .. $];
            }
            cback(rbyte);
            _rSize += rbyte.length;
            rsite = 0;
            ++rcount;
        }
        return _wSize - _rSize;
    }

    pragma(inline)
    ubyte[] readAll() //返回的数据有copy
    {
		size_t maxlen = _wSize - _rSize;
		ubyte[] rbyte = new ubyte[maxlen];
		read(rbyte);
        return rbyte;
    }

    size_t readUtil(in ubyte[] data, void delegate(in ubyte[]) cback) //data.length 必须小于分段大小！
    {
        if (data.length == 0 || isEof() || data.length >= _sectionSize)
            return 0;
        auto ch = data[0];
        
        size_t size = _rSize;
        size_t wsite = writeSite();
        size_t wcount = writeCount();
        ubyte[] byptr, by;
        while (!isEof())
        {
			size_t rcount = readCount();
			size_t rsite = readSite();
            by = _buffer[rcount];
            if (rcount == wcount)
            {
                byptr = by[rsite .. wsite];
            }
            else
            {
                byptr = by[rsite .. $];
            }
			ptrdiff_t site = findUbyte(byptr,ch);
            if (site == -1)
            {
                cback(byptr);
                rsite = 0;
                ++rcount;
                _rSize += byptr.length;
            }
            else
            {
                auto tsize = (_rSize + site);
                size_t i = 1;
                for (++tsize; i < data.length && tsize < _wSize; ++i, ++tsize)
                {
                    if (data[i] != this[tsize])
                    {
						auto len = site + i;
						//前面查找确认不是的数据就回调过去
						if(byptr.length >= len) {
							cback(byptr[0..len]); 
						} else {
							auto tlen = len - byptr.length;
							cback(byptr);
							rcount ++ ;
							byptr = _buffer[rcount];
							cback(byptr[0..tlen]);
						}
						_rSize = tsize;
                        goto next; //没找对，进行下次查找
                    }
                    else
                    {
                        continue;
                    }
                } //循环正常执行完毕,表示
                _rSize = tsize;
                cback(byptr[0 .. site]);
                return (_rSize - size);

            next:
                continue;
            }
        }
        return (_rSize - size);
    }

    pragma(inline)
    ref ubyte opIndex(size_t i)
    {
        assert(i < _wSize);
        size_t count = i / _sectionSize;
        size_t site = i % _sectionSize;
        return _buffer[count][site];
    }

	ubyte[] opSlice(size_t i, size_t j)
	{
		j = j > _wSize ? _wSize : j;
		auto tsize = _rSize;
		auto len = j - i;
		if(len <= 0) return (ubyte[]).init;
		ubyte[] data = new ubyte[len];
		read(data);
		_rSize = tsize;
		return data;
	}

	pragma(inline)
	ubyte[] opSlice()
	{
		return readAll();
	}

    pragma(inline,true)
    @property readSize() const
    {
        return _rSize;
    }

    pragma(inline,true)
    @property readCount() const
    {
        return _rSize / _sectionSize;
    }

    pragma(inline,true)
    @property readSite() const
    {
        return _rSize % _sectionSize;
    }

    pragma(inline,true)
    @property writeCount() const
    {
        return _wSize / _sectionSize;
    }

    pragma(inline,true)
    @property writeSite() const
    {
        return _wSize % _sectionSize;
    }

	ptrdiff_t findUbyte(in ref ubyte[] data, ubyte ch)
	{
		ptrdiff_t index = -1;
		for(size_t id = 0; id < data.length; ++id)
		{
			if(ch == data[id]){
				index = cast(ptrdiff_t)id;
				break;
			}
		}
		return index;
	}

/*	ptrdiff_t findUbyteArray(in ref ubyte[] data, ref in ubyte[] ch)
	{
		assert(data.length >= ch.length);
		auto begin = findUbyte(data,ch[0]);
		if(begin < 0) return -1;

	}*/

private:
    pragma(inline,true)
    @property bool isEof() const
    {
        return (_rSize >= _wSize);
    }

    size_t _rSize;
    size_t _wSize;
    BufferVector _buffer;
    size_t _sectionSize;
    IAllocator _alloc;
}

unittest
{
    import std.stdio;
    import std.experimental.allocator.mallocator;

    string data = "hello world. hello world. hello world. hello world. hello world. hello world. hello world. hello world. hello world. hello world. hello world. hello world. hello world.";
    auto buf = new SectionBuffer(5);
    buf.reserve(data.length);
    writeln("buffer max size:", buf.maxSize());
    writeln("buffer  size:", buf.length);
    writeln("buffer write :", buf.write(cast(ubyte[]) data));
    writeln("buffer  size:", buf.length);
    ubyte[] dt;
    dt.length = 13;
    writeln("buffer read size =", buf.read(dt));
    writeln("buffer read data =", cast(string) dt);

    writeln("\r\n");

    auto buf2 = new SectionBuffer(3);
    writeln("buffer2 max size:", buf2.maxSize());
    writeln("buffer2  size:", buf2.length);
    writeln("buffer2 write :", buf2.write(cast(ubyte[]) data));
    writeln("buffer2  size:", buf2.length);
    ubyte[] dt2;
    dt2.length = 13;
    writeln("buffer2 read size =", buf2.read(dt2));
    writeln("buffer2 read data =", cast(string) dt2);

    writeln("\r\nswitch \r\n");

    SectionBuffer.BufferVector tary;
    buf.swap(tary);
    writeln("buffer  size:", buf.length);
    writeln("buffer max size:", buf.maxSize());
    writeln("Array!(ubyte[]) length : ", tary.length);
    size_t len = tary.length < 5 ? tary.length : 5;
    for (size_t i = 0; i < len; ++i)
    {
        write("i = ", i);
        writeln("   ,ubyte[] = ", cast(string) tary[i]);
    }

    buf.reserve(data.length);
    writeln("buffer max size:", buf.maxSize());
    writeln("buffer  size:", buf.length);
    writeln("buffer write :", buf.write(cast(ubyte[]) data));
    writeln("buffer  size:", buf.length);
    writeln("\n 1.");
    dt = buf.readLine!false();
    writeln("buffer read line size =", dt.length);
    writeln("buffer readline :", cast(string) dt);
    writeln("read size : ", buf._rSize);
    writeln("\n 2.");

    /* dt.length = 1;
    writeln("buffer read size =",buf.read(dt));
    writeln("buffer read data =",cast(string)dt);*/

    dt = buf.readLine!false();
    writeln("buffer read line size =", dt.length);
    writeln("buffer read line data =", cast(string) dt);
    writeln("read size : ", buf._rSize);
    writeln("\n 3.");

    dt = buf.readLine!false();
    writeln("buffer read line size =", dt.length);
    writeln("buffer read line data =", cast(string) dt);
    writeln("read size : ", buf._rSize);
    buf.rest();
    int j = 0;
    while (!buf.eof())
    {
        ++j;
        writeln("\n ", j, " . ");
        dt = buf.readLine!false();
        writeln("buffer read line size =", dt.length);
        writeln("buffer readline :", cast(string) dt);
        writeln("read size : ", buf._rSize);
    }

    data = "ewarwaerewtretr54654654kwjoerjopiwrjeo;jmq;lkwejoqwiurwnblknhkjhnjmq1111dewrewrjmqrtee";
    buf = new SectionBuffer(5);
    // buf.reserve(data.length);
    writeln("buffer max size:", buf.maxSize());
    writeln("buffer  size:", buf.length);
    writeln("buffer write :", buf.write(cast(ubyte[]) data));
    writeln("buffer  size:", buf.length);

    foreach (i; 0 .. 4)
    {
        ubyte[] tbyte;
        writeln("\n\nbuffer readutil  size:", buf.readUtil(cast(ubyte[]) "jmq",
            delegate(in ubyte[] data) {
            //writeln("\t data :", cast(string)data);
            //writeln("\t read size: ", buf._rSize);
            tbyte ~= data;
        }));
        if (tbyte.length > 0)
        {
            writeln("\n buffer readutil data:", cast(string) tbyte);
            writeln("\t _Rread size: ", buf._rSize);
            writeln("\t _Wread size: ", buf._wSize);
        }
        else
        {
            writeln("\n buffer readutil data eof");
        }
    }
    //buf.clear();
    //buf2.clear();
    writeln("hahah");
    destroy(buf);
    destroy(buf2);
}
