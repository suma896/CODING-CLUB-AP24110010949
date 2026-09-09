-- =====================================================================
-- LIBRARY LENDING SYSTEM — Relational Database Design
-- Based on: Elmasri & Navathe, Fundamentals of Database Systems
-- Dialect: PostgreSQL (notes included for MySQL/SQLite where it differs)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. BOOK  (title-level catalog entry — shared across all copies)
-- ---------------------------------------------------------------------
CREATE TABLE Book (
    isbn        VARCHAR(20)   PRIMARY KEY,
    title       VARCHAR(255)  NOT NULL,
    author      VARCHAR(255)  NOT NULL,
    publisher   VARCHAR(255),
    pub_year    SMALLINT      CHECK (pub_year > 0),
    category    VARCHAR(100)
);

-- ---------------------------------------------------------------------
-- 2. BOOKCOPY  (one row per physical copy on the shelf)
--    This is what actually carries "availability" — not Book.
-- ---------------------------------------------------------------------
CREATE TABLE BookCopy (
    copy_id     SERIAL        PRIMARY KEY,           -- INTEGER AUTO_INCREMENT in MySQL
    isbn        VARCHAR(20)   NOT NULL,
    shelf       VARCHAR(50),
    section     VARCHAR(50),
    status      VARCHAR(15)   NOT NULL DEFAULT 'available'
                CHECK (status IN ('available', 'loaned', 'lost', 'maintenance')),
    CONSTRAINT fk_bookcopy_book
        FOREIGN KEY (isbn) REFERENCES Book(isbn)
        ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE INDEX idx_bookcopy_isbn   ON BookCopy(isbn);
CREATE INDEX idx_bookcopy_status ON BookCopy(status);

-- ---------------------------------------------------------------------
-- 3. MEMBER
-- ---------------------------------------------------------------------
CREATE TABLE Member (
    member_id       SERIAL       PRIMARY KEY,
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    address         VARCHAR(255),
    phone           VARCHAR(20),
    email           VARCHAR(255) UNIQUE,
    membership_date DATE         NOT NULL DEFAULT CURRENT_DATE
);

-- ---------------------------------------------------------------------
-- 4. LIBRARIAN
-- ---------------------------------------------------------------------
CREATE TABLE Librarian (
    librarian_id SERIAL       PRIMARY KEY,
    name         VARCHAR(200) NOT NULL,
    email        VARCHAR(255) UNIQUE,
    hire_date    DATE         NOT NULL
);

-- ---------------------------------------------------------------------
-- 5. LOAN  (the borrowing transaction — this IS the loan history)
-- ---------------------------------------------------------------------
CREATE TABLE Loan (
    loan_id             SERIAL      PRIMARY KEY,
    copy_id             INTEGER     NOT NULL,
    member_id           INTEGER     NOT NULL,
    issued_by           INTEGER,                 -- librarian who issued it
    received_by         INTEGER,                 -- librarian who processed the return
    borrow_date         DATE        NOT NULL DEFAULT CURRENT_DATE,
    due_date            DATE        NOT NULL,
    return_date         DATE,                    -- NULL while book is still out
    status              VARCHAR(15) NOT NULL DEFAULT 'borrowed'
                        CHECK (status IN ('borrowed', 'returned', 'overdue')),
    fine_amount         NUMERIC(8,2) DEFAULT 0.00,

    CONSTRAINT fk_loan_copy
        FOREIGN KEY (copy_id) REFERENCES BookCopy(copy_id),
    CONSTRAINT fk_loan_member
        FOREIGN KEY (member_id) REFERENCES Member(member_id),
    CONSTRAINT fk_loan_issued_by
        FOREIGN KEY (issued_by) REFERENCES Librarian(librarian_id),
    CONSTRAINT fk_loan_received_by
        FOREIGN KEY (received_by) REFERENCES Librarian(librarian_id),

    CONSTRAINT chk_due_after_borrow    CHECK (due_date >= borrow_date),
    CONSTRAINT chk_return_after_borrow CHECK (return_date IS NULL OR return_date >= borrow_date)
);

CREATE INDEX idx_loan_member ON Loan(member_id);
CREATE INDEX idx_loan_copy   ON Loan(copy_id);
CREATE INDEX idx_loan_status ON Loan(status);

-- ---------------------------------------------------------------------
-- THE CORE CONSTRAINT: a copy can only be on ONE active (unreturned)
-- loan at a time. A plain UNIQUE(copy_id) would forbid ever lending the
-- same copy out twice in its lifetime — wrong. We only want uniqueness
-- while the loan is still open (return_date IS NULL).
-- ---------------------------------------------------------------------
CREATE UNIQUE INDEX uq_active_loan_per_copy
    ON Loan(copy_id)
    WHERE return_date IS NULL;
-- (SQLite/older MySQL without partial indexes: enforce this instead via
--  the trigger below, which checks for an existing open loan.)

-- =====================================================================
-- 6. TRIGGERS — keep BookCopy.status in sync with Loan activity,
--    and refuse to issue a copy that isn't available.
-- =====================================================================

-- (a) Before inserting a new loan: copy must currently be 'available'
CREATE OR REPLACE FUNCTION fn_check_copy_available()
RETURNS TRIGGER AS $$
DECLARE
    copy_status VARCHAR(15);
BEGIN
    SELECT status INTO copy_status FROM BookCopy WHERE copy_id = NEW.copy_id FOR UPDATE;

    IF copy_status IS NULL THEN
        RAISE EXCEPTION 'Copy % does not exist', NEW.copy_id;
    ELSIF copy_status <> 'available' THEN
        RAISE EXCEPTION 'Copy % is not available (status: %)', NEW.copy_id, copy_status;
    END IF;

    -- mark it loaned
    UPDATE BookCopy SET status = 'loaned' WHERE copy_id = NEW.copy_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_copy_available
BEFORE INSERT ON Loan
FOR EACH ROW EXECUTE FUNCTION fn_check_copy_available();

-- (b) When a loan is updated with a return_date, flip the copy back
--     to 'available' and set the loan status to 'returned'.
CREATE OR REPLACE FUNCTION fn_process_return()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.return_date IS NOT NULL AND OLD.return_date IS NULL THEN
        UPDATE BookCopy SET status = 'available' WHERE copy_id = NEW.copy_id;
        NEW.status := 'returned';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_process_return
BEFORE UPDATE ON Loan
FOR EACH ROW EXECUTE FUNCTION fn_process_return();

-- =====================================================================
-- 7. SAMPLE QUERIES / OPERATIONS
-- =====================================================================

-- (a) ISSUE A BOOK — find an available copy of an ISBN, then create the loan.
--     Do this as one transaction; the trigger above blocks a race condition
--     where two people try to grab the same copy at once.
BEGIN;
    -- pick any available copy of the desired ISBN
    -- (application layer supplies the chosen copy_id, e.g. from this SELECT)
    SELECT copy_id FROM BookCopy
    WHERE isbn = '978-0-13-186321-4' AND status = 'available'
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    INSERT INTO Loan (copy_id, member_id, issued_by, borrow_date, due_date)
    VALUES (:copy_id, 42, 3, CURRENT_DATE, CURRENT_DATE + INTERVAL '14 days');
COMMIT;

-- (b) RETURN A BOOK
UPDATE Loan
SET return_date = CURRENT_DATE,
    received_by = 3
WHERE loan_id = 501;
-- (trigger fn_process_return sets status='returned' and frees the copy)

-- (c) FIND OVERDUE BOOKS (not yet returned, past due date)
SELECT l.loan_id, m.first_name, m.last_name, b.title, bc.copy_id, l.due_date,
       CURRENT_DATE - l.due_date AS days_overdue
FROM Loan l
JOIN Member m   ON l.member_id = m.member_id
JOIN BookCopy bc ON l.copy_id = bc.copy_id
JOIN Book b     ON bc.isbn = b.isbn
WHERE l.return_date IS NULL
  AND l.due_date < CURRENT_DATE
ORDER BY days_overdue DESC;

-- Optional: a matching maintenance query to actually flag them as 'overdue'
UPDATE Loan
SET status = 'overdue'
WHERE return_date IS NULL AND due_date < CURRENT_DATE AND status <> 'overdue';

-- (d) FIND BOOKS CURRENTLY AVAILABLE (title + count of available copies)
SELECT b.isbn, b.title, b.author, COUNT(bc.copy_id) AS available_copies
FROM Book b
JOIN BookCopy bc ON b.isbn = bc.isbn
WHERE bc.status = 'available'
GROUP BY b.isbn, b.title, b.author
HAVING COUNT(bc.copy_id) > 0
ORDER BY b.title;

-- (e) BORROWING HISTORY OF A MEMBER (all loans, past and present)
SELECT l.loan_id, b.title, bc.copy_id, l.borrow_date, l.due_date, l.return_date, l.status
FROM Loan l
JOIN BookCopy bc ON l.copy_id = bc.copy_id
JOIN Book b      ON bc.isbn = b.isbn
WHERE l.member_id = 42
ORDER BY l.borrow_date DESC;

-- (f) BONUS: block new loans for members who currently have an overdue book
--     (enforced in the application layer or as an extra trigger check)
SELECT DISTINCT member_id
FROM Loan
WHERE return_date IS NULL AND due_date < CURRENT_DATE;
