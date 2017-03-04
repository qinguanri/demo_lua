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
        // 每行格式
        // oid,like_uids 101:[1,2]

        line, err := rd.ReadString('\n') //以'\n'为结束符读入一行
        
        if err != nil || io.EOF == err {
            break
        }
        s := strings.Split(line, ":")
        oid := s[0]
        like_list := strings.TrimSpace(s[1])
        like_list = strings.Replace(like_list, "[", "", -1)
        like_list = strings.Replace(like_list, "]", "", -1)
        like_list = strings.Split(like_list, ",")
        
        // 写入redis
        for i :=0, i<len(like_list); i++ {
            _, err = c.Do("zadd", "like:" + oid, 1, uid)
            if err != nil {
                fmt.Println(err)
                return
            }
        }
    }
}