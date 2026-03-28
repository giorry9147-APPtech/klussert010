(() => {
    const menuToggle = document.querySelector(".menu-toggle");
    const navWrap = document.querySelector(".nav-wrap");
    const navLinks = Array.from(document.querySelectorAll(".nav-list a"));
    const revealItems = document.querySelectorAll("[data-reveal]");

    const setMenuState = (open) => {
        if (!menuToggle || !navWrap) return;
        menuToggle.setAttribute("aria-expanded", String(open));
        navWrap.setAttribute("data-open", String(open));
        document.body.style.overflow = open ? "hidden" : "";
    };

    if (menuToggle && navWrap) {
        menuToggle.addEventListener("click", () => {
            const isOpen = navWrap.getAttribute("data-open") === "true";
            setMenuState(!isOpen);
        });

        navWrap.addEventListener("click", (event) => {
            if (event.target === navWrap) {
                setMenuState(false);
            }
        });

        navLinks.forEach((link) => {
            link.addEventListener("click", () => setMenuState(false));
        });

        document.addEventListener("keydown", (event) => {
            if (event.key === "Escape") {
                setMenuState(false);
            }
        });
    }

    if ("IntersectionObserver" in window) {
        const revealObserver = new IntersectionObserver(
            (entries) => {
                entries.forEach((entry) => {
                    if (entry.isIntersecting) {
                        entry.target.classList.add("revealed");
                        revealObserver.unobserve(entry.target);
                    }
                });
            },
            {
                threshold: 0.14,
                rootMargin: "0px 0px -50px 0px"
            }
        );

        revealItems.forEach((item) => revealObserver.observe(item));
    } else {
        revealItems.forEach((item) => item.classList.add("revealed"));
    }

    const sectionIds = ["diensten", "werkwijze", "tarieven", "projecten", "reviews", "contact"];
    const sections = sectionIds
        .map((id) => document.getElementById(id))
        .filter(Boolean);

    const setActiveLink = () => {
        const offset = 140;
        const current = sections.findLast((section) => window.scrollY + offset >= section.offsetTop);
        navLinks.forEach((link) => {
            const href = link.getAttribute("href") || "";
            if (href.startsWith("#") && current && href === `#${current.id}`) {
                link.classList.add("active");
                link.setAttribute("aria-current", "page");
            } else {
                link.classList.remove("active");
                link.removeAttribute("aria-current");
            }
        });
    };

    setActiveLink();
    window.addEventListener("scroll", setActiveLink, { passive: true });
})();
