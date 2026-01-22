package com.test

class TestCase2 {
    
    void existingMethod() {
        println "existing"
    }
    
    // ADICIONAR ESTAS LINHAS - P1 dentro do diff
    String insecureUrl = "http://api.example.com"
    
    void callApi() {
        // usar insecureUrl
    }
}