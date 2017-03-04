package main

import (
    "fmt"
    "strings"
    "os"
    "github.com/garyburd/redigo/redis"
    "bufio"
    "io"
)

func main() {
    c, err := redis.Dial("tcp", "127.0.0.1:6379")
    if err != nil {
        fmt.Println(err)
        return
    }

    defer c.Close()
    f, err := os.Open("friend.txt")
    if err != nil {
        panic(err)
    }
    defer f.Close()

    rd := bufio.NewReader(f)
    for {
        // 每行格式
        // uid,friend_id 
        // 1,2

        line, err := rd.ReadString('\n') //以'\n'为结束符读入一行
        
        if err != nil || io.EOF == err {
            break
        }
        s := strings.Split(line, ",")
        uid := s[0]
        friend_id := strings.TrimSpace(s[1])

        // 写入redis,双向的好友关系
        _, err = c.Do("zadd", "friend:" + uid, 0, friend_id)
        if err != nil {
            fmt.Println(err)
            return
        }

        _, err = c.Do("zadd", "friend:" + friend_id, 0, uid)
        if err != nil {
            fmt.Println(err)
            return
        }
    }
}
