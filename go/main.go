package main

import (
    "fmt"
    "strings"
    "os"
    "github.com/garyburd/redigo/redis"
)

func main() {
    c, err := redis.Dial("tcp", "127.0.0.1:6379")
    if err != nil {
        fmt.Println(err)
        return
    }

    defer c.Close()
    f, err := os.Open("user.txt")
    if err != nil {
        panic(err)
    }
    defer f.Close()

    rd := bufio.NewReader(f)
    for {
        line, err := rd.ReadString('\n') //以'\n'为结束符读入一行
        
        if err != nil || io.EOF == err {
            break
        }
        s := strings.Split(line, ",")
        uid := s[0]
        nickname := strings.TrimSpace(s[1])


        // 写入redis
        _, err = c.Do("HSET", "user", uid, nickname)
        if err != nil {
            fmt.Println(err)
            return
        }
    }
}