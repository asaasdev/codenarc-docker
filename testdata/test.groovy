package test

import org.springframework.web.util.UriComponentsBuilder

class Test {

    // P1 - ForceHttps
    String url = "http://example.com"
    
    // P1 - VerifyUriComponentsBuilderVulnerability  
    UriComponentsBuilder builder = UriComponentsBuilder.fromHttpUrl("test")

    boolean before() {
        return true // P2 - ImplicitReturnStatement
    }

    boolean after() { true } // P2 - ImplicitReturnStatement

    void after() { // P2 - EmptyMethod
    }
    
    // P2 - Multiple violations
    def x = new ArrayList() // P2 - ExplicitArrayListInstantiation
    String msg = 'Hello ${name}' // P2 - GStringExpressionWithinString
    
    void testMethod() {
        if (true) { // P2 - ConstantIfExpression
            println "test" // P2 - PrintlnRule
        }
        
        // P2 - AssignmentInConditional
        if (x = 5) {
            return
        }
        
        // P2 - ComparisonWithSelf
        if (x == x) {
            return
        }
    }
}