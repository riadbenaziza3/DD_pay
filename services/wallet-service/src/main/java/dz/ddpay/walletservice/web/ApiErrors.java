package dz.ddpay.walletservice.web;

import java.net.URI;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.MissingRequestHeaderException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import dz.ddpay.walletservice.ledger.WalletException;

/** Errors come back as standard JSON with a stable "code" the app can switch on. */
@RestControllerAdvice
public class ApiErrors {

    private static final Logger log = LoggerFactory.getLogger(ApiErrors.class);

    @ExceptionHandler(WalletException.class)
    public ProblemDetail wallet(WalletException e) {
        ProblemDetail p = ProblemDetail.forStatusAndDetail(e.status(), e.getMessage());
        p.setType(URI.create("urn:ddpay:wallet:" + e.code()));
        p.setProperty("code", e.code());
        return p;
    }

    @ExceptionHandler(MissingRequestHeaderException.class)
    public ProblemDetail missingHeader(MissingRequestHeaderException e) {
        ProblemDetail p = ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST,
            "Missing header: " + e.getHeaderName());
        p.setProperty("code", "MISSING_HEADER");
        return p;
    }

    @ExceptionHandler(DataIntegrityViolationException.class)
    public ProblemDetail conflict(DataIntegrityViolationException e) {
        log.warn("Rejected by a database constraint: {}", e.getMostSpecificCause().getMessage());
        ProblemDetail p = ProblemDetail.forStatusAndDetail(HttpStatus.CONFLICT,
            "The operation conflicts with existing data.");
        p.setProperty("code", "CONFLICT");
        return p;
    }
}
